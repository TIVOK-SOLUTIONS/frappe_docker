# CI/CD Pipeline — Custom Frappe Image

This documents the GitHub Actions pipeline that builds and publishes the
custom Frappe v16 image containing **erpnext**, **hrms**, **ipstc**, and
**ipstc_hrms**.

---

## How it works

```
push to develop  ──►  Build image  ──►  Smoke test  ──►  Auto-deploy to dev server
push to main     ──►  Build image  ──►  Smoke test  ──►  Auto-deploy to staging server
```

**First deploy on each server is always manual** (create site, install apps — done once).
Every push after that is fully automatic — new image built, deployed, and migrated.

The image is pushed to **GitHub Container Registry (GHCR)** with two tags:

| Tag | Example | Use |
|---|---|---|
| Branch name | `ghcr.io/tivok-solutions/frappe_docker:develop` | Always points to the latest build for that branch |
| Commit SHA | `ghcr.io/tivok-solutions/frappe_docker:abc1234` | Immutable — pin a specific build |

Branch mapping:

| Branch | Environment | Server |
|---|---|---|
| `develop` | dev | dev server |
| `main` | staging | staging server |
| `develop` | ipstc/ipstc_hrms branch | `develop` |
| `main` | ipstc/ipstc_hrms branch | `main` |

---

## One-time GitHub setup

### 1. Create the `develop` branch

```bash
git checkout -b develop
git push -u origin develop
```

### 2. Repository secret — `APPS_PAT`

Set at **Settings → Secrets and variables → Actions → New repository secret**

| Secret | Description |
|---|---|
| `APPS_PAT` | Classic PAT (`repo` scope) for cloning ipstc and ipstc-hrms during the Docker build |

**Creating `APPS_PAT`:**
1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)**
2. Generate new token → select `repo` scope
3. Save as the `APPS_PAT` repository secret

> Injected via BuildKit secret mount — never written into any image layer or visible in `docker history`.

### 3. Environment secrets — dev and staging

Set at **Settings → Environments** — create two environments: `dev` and `staging`.
Add these secrets to **each** environment:

| Secret | Example | Description |
|---|---|---|
| `SSH_HOST` | `167.99.231.229` | Server IP or hostname |
| `SSH_USER` | `root` | SSH login user |
| `SSH_KEY` | `-----BEGIN OPENSSH...` | Private SSH key for the server |
| `DEPLOY_PATH` | `/opt/frappe-docker` | Path to frappe-docker on the server |
| `SITE_NAME` | `167.99.231.229` | Frappe site name (used for migrations) |

### 4. Make the GHCR package public (recommended)

Avoids needing a pull token on every server.

Go to `https://github.com/TIVOK-SOLUTIONS/frappe_docker/pkgs/container/frappe_docker`
→ **Package settings** → **Change visibility** → **Public**

If kept private, each server must authenticate — see [GHCR pull token](#1-ghcr-pull-token) below.

---

## Server setup (run once per server)

Assumes Docker and Docker Compose are already installed.

```bash
# Clone the repo
git clone https://github.com/TIVOK-SOLUTIONS/frappe_docker.git /opt/frappe-docker
cd /opt/frappe-docker

# Create .env from template
cp example.env .env
```

Edit `.env` and set:

```env
CUSTOM_IMAGE=ghcr.io/tivok-solutions/frappe_docker
CUSTOM_TAG=develop                # or main for staging

DB_PASSWORD=a-strong-password
FRAPPE_SITE_NAME_HEADER=<server-ip>
HTTP_PUBLISH_PORT=80
```

---

## First-time site creation (manual, done once)

```bash
cd /opt/frappe-docker

# Start the stack
docker compose \
  -f compose.yaml \
  -f overrides/compose.mariadb.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.noproxy.yaml \
  up -d

# Create the site (use the server IP as the site name)
docker compose exec backend bench new-site <server-ip> \
  --db-root-password <DB_PASSWORD> \
  --admin-password <ADMIN_PASSWORD>

# Install apps in order
docker compose exec backend bench --site <server-ip> install-app erpnext
docker compose exec backend bench --site <server-ip> install-app hrms
docker compose exec backend bench --site <server-ip> install-app ipstc
docker compose exec backend bench --site <server-ip> install-app ipstc_hrms

# Restart frontend to pick up the new site
docker compose restart frontend
```

After this, every push to `develop` or `main` deploys automatically — no manual steps needed.

---

## Automatic deployment (every push)

The pipeline runs these steps on the server automatically after a successful build and smoke test:

1. `docker compose pull` — pulls the new image
2. `docker compose up -d --remove-orphans` — restarts containers with the new image
3. `bench --site all migrate` — applies any pending DB migrations on all sites

No SSH access needed after the first-time setup.

---

## Triggering a build

### Automatic

```bash
git push origin develop   # builds image with ipstc@develop, deploys to dev
git push origin main      # builds image with ipstc@main, deploys to staging
```

### Manual

Go to **Actions → Build & Push → Run workflow** and pick the branch.

Use this after committing directly to `ipstc` or `ipstc_hrms` — the build
pulls the latest commit on the matching branch at build time.

---

## Secrets & credentials summary

### GitHub repository secret

| Secret | Type | Scope | Purpose |
|---|---|---|---|
| `APPS_PAT` | Classic PAT | `repo` | Clones private app repos during Docker build |

### GitHub environment secrets (dev + staging)

| Secret | Purpose |
|---|---|
| `SSH_HOST` | Server to deploy to |
| `SSH_USER` | SSH login user |
| `SSH_KEY` | Private key for SSH access |
| `DEPLOY_PATH` | frappe-docker directory on the server |
| `SITE_NAME` | Frappe site name for migrations |

### Server credentials

#### 1. GHCR pull token
Only needed if the GHCR package is **private**.

- **Type**: Classic PAT, `read:packages` scope
- **Stored at**: `~/.docker/config.json`
- **Setup**:
  ```bash
  echo "<token>" | docker login ghcr.io -u <github-username> --password-stdin
  ```

#### 2. `.env` file
- **Path**: `/opt/frappe-docker/.env`
- **Created from**: `cp example.env .env`

| Variable | Example | Description |
|---|---|---|
| `CUSTOM_IMAGE` | `ghcr.io/tivok-solutions/frappe_docker` | Image name pulled from GHCR |
| `CUSTOM_TAG` | `develop` | Image tag — branch name or commit SHA |
| `DB_PASSWORD` | `strongpassword` | MariaDB root and site DB password |
| `FRAPPE_SITE_NAME_HEADER` | `167.99.231.229` | Server IP — used as the site name |
| `HTTP_PUBLISH_PORT` | `80` | Port the site is served on |

#### 3. Compose files
- **Path**: `/opt/frappe-docker/`
- **Cloned from**: `https://github.com/TIVOK-SOLUTIONS/frappe_docker.git`

| File | Purpose |
|---|---|
| `compose.yaml` | Core services (backend, frontend, websocket, workers, scheduler) |
| `overrides/compose.mariadb.yaml` | MariaDB database |
| `overrides/compose.redis.yaml` | Redis cache and queue |
| `overrides/compose.noproxy.yaml` | Exposes port 80 directly (no Traefik) |