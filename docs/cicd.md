# CI/CD Pipeline — Custom Frappe Image

This documents the GitHub Actions pipeline that builds and publishes the
custom Frappe v16 image containing **erpnext**, **hrms**, **ipstc**, and
**ipstc_hrms**.

---

## How it works

```
push to develop  ──►  Build image  ──►  Smoke test  ──►  Image ready on GHCR
push to main     ──►  Build image  ──►  Smoke test  ──►  Image ready on GHCR
```

The image is pushed to **GitHub Container Registry (GHCR)** with two tags:

| Tag | Example | Use |
|---|---|---|
| Branch name | `ghcr.io/tivok-solutions/frappe_docker:develop` | Always points to the latest build for that branch |
| Commit SHA | `ghcr.io/tivok-solutions/frappe_docker:abc1234` | Immutable — pin a specific build |

Custom app branches follow the triggering branch automatically:

| Trigger branch | ipstc branch | ipstc_hrms branch |
|---|---|---|
| `develop` | `develop` | `develop` |
| `main` | `main` | `main` |

Once the pipeline finishes, **you pull the image on the server manually.**

---

## One-time setup

### 1. Create the `develop` branch

```bash
git checkout -b develop
git push -u origin develop
```

### 2. Add GitHub Secrets

**Settings → Secrets and variables → Actions → New repository secret**

| Secret | Description |
|---|---|
| `APPS_PAT` | Classic PAT for cloning the private custom apps. See [Creating APPS_PAT](#creating-apps_pat) below. |

#### Creating `APPS_PAT`

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)**
2. Click **Generate new token**
3. Select the `repo` scope
4. Copy the token and save it as the `APPS_PAT` repository secret

> The PAT is injected into the Docker build via a BuildKit secret mount and is
> never written into any image layer or visible in `docker history`.

### 3. Make the GHCR package public (recommended)

This avoids needing a pull token on every server.

Go to `https://github.com/TIVOK-SOLUTIONS/frappe_docker/pkgs/container/frappe_docker`
→ **Package settings** → **Change visibility** → **Public**

If you keep it private, see [GHCR pull token](#1-ghcr-pull-token) below.

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
CUSTOM_TAG=develop                # or main

DB_PASSWORD=a-strong-password
FRAPPE_SITE_NAME_HEADER=<server-ip>   # e.g. 192.168.1.100
HTTP_PUBLISH_PORT=80
```

---

## First-time site creation

```bash
cd /opt/frappe-docker

# Start the stack
docker compose \
  -f compose.yaml \
  -f overrides/compose.mariadb.yaml \
  -f overrides/compose.redis.yaml \
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
```

This is a one-time step. Subsequent updates only need a pull.

---

## Deploying an update

After the CI pipeline completes:

```bash
cd /opt/frappe-docker

# Pull the new image (branch tag always points to latest)
docker compose pull

# Restart with the new image
docker compose up -d --remove-orphans

# Run any pending migrations
docker compose exec backend bench --site <server-ip> migrate
```

To deploy a specific commit instead of the latest, set `CUSTOM_TAG` in `.env`
to the commit SHA shown in the Actions run, then repeat the steps above.

---

## Triggering a build

### Automatic

```bash
git push origin develop   # builds image with ipstc@develop
git push origin main      # builds image with ipstc@main
```

### Manual

Go to **Actions → Build & Push → Run workflow** and pick the branch.

Use this after committing to `ipstc` or `ipstc_hrms` directly — the build
pulls the latest commit on the matching branch at build time.

---

## Secrets & credentials summary

### GitHub Actions secret
Set at **Settings → Secrets and variables → Actions**

| Secret | Type | Permissions needed | Purpose |
|---|---|---|---|
| `APPS_PAT` | Classic PAT | `repo` scope | Clones private app repos during the Docker build. Injected via BuildKit secret — never baked into the image. |

---

### Server credentials
Configured directly on each server — not stored in GitHub.

#### 1. GHCR pull token
Only needed if the GHCR package is **private**.

- **Type**: Classic PAT, `read:packages` scope
- **Stored at**: `~/.docker/config.json` (written automatically by `docker login`)
- **How to create**:
  1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)**
  2. Select only the `read:packages` scope
  3. Run on each server:
  ```bash
  echo "<token>" | docker login ghcr.io -u <your-github-username> --password-stdin
  ```

#### 2. `.env` file
- **Path**: `/opt/frappe-docker/.env`
- **Created from**: `cp example.env .env`

Required variables:

| Variable | Example | Description |
|---|---|---|
| `CUSTOM_IMAGE` | `ghcr.io/tivok-solutions/frappe_docker` | Image name pulled from GHCR |
| `CUSTOM_TAG` | `develop` | Image tag — branch name or commit SHA |
| `DB_PASSWORD` | `strongpassword` | MariaDB root and site DB password |
| `FRAPPE_SITE_NAME_HEADER` | `192.168.1.100` | Server IP — used as the site name |
| `HTTP_PUBLISH_PORT` | `80` | Port the site is served on |

#### 3. Compose files
- **Path**: `/opt/frappe-docker/`
- **Cloned from**: `https://github.com/TIVOK-SOLUTIONS/frappe_docker.git`
- **Files used at runtime**:

| File | Purpose |
|---|---|
| `compose.yaml` | Core services (backend, frontend, websocket, workers, scheduler) |
| `overrides/compose.mariadb.yaml` | MariaDB database |
| `overrides/compose.redis.yaml` | Redis cache and queue |