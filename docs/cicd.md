# CI/CD Pipeline — Custom Frappe Image

sThis documents the GitHub Actions pipeline that builds and publishes the
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
| Branch name | `ghcr.io/org/repo:develop` | Always points to the latest build for that branch |
| Commit SHA | `ghcr.io/org/repo:abc1234` | Immutable — pin a specific build |

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
| `APPS_PAT` | Fine-grained PAT for cloning the private custom apps. See [Creating APPS_PAT](#creating-apps_pat) below. |

#### Creating `APPS_PAT`

1. Go to **GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens**
2. Click **Generate new token**
3. Set **Resource owner** to `TIVOK-SOLUTIONS`
4. Under **Repository access** select: `ipstc` and `ipstc-hrms`
5. Under **Permissions → Repository permissions** set **Contents** to `Read-only`
6. Copy the token and save it as the `APPS_PAT` repository secret

> The PAT is injected into the Docker build via a BuildKit secret mount and is
> never written into any image layer or visible in `docker history`.

---

## Server setup (run once per server)

```bash
# Install Docker
curl -fsSL https://get.docker.com | sh
sudo usermod -aG docker $USER
# Log out and back in so the group takes effect
```

```bash
# Create the deploy directory
sudo mkdir -p /opt/frappe-docker
sudo chown $USER:$USER /opt/frappe-docker
cd /opt/frappe-docker
git clone https://github.com/TIVOK-SOLUTIONS/frappe_docker.git .

# Create .env from template
cp example.env .env
```

Edit `.env` and set at minimum:

```env
DB_PASSWORD=a-strong-password
FRAPPE_SITE_NAME_HEADER=dev.example.com
```

### Authenticate with GHCR on the server

The server needs a token to pull the image. Create a classic PAT with
`read:packages` scope, then run:

```bash
echo "<your-pat>" | docker login ghcr.io -u <your-github-username> --password-stdin
```

Do this once — Docker stores the credentials in `~/.docker/config.json`.

---

## First-time site creation

Start the stack and create the site once. Replace the image tag with the one
produced by the first pipeline run.

```bash
cd /opt/frappe-docker

# Set the custom image in .env
echo "CUSTOM_IMAGE=ghcr.io/tivok-solutions/frappe_docker" >> .env
echo "CUSTOM_TAG=develop" >> .env   # or use a commit SHA for a pinned version

# Start the stack
docker compose \
  -f compose.yaml \
  -f overrides/compose.mariadb.yaml \
  -f overrides/compose.redis.yaml \
  up -d

# Create the site
docker compose exec backend bench new-site dev.example.com \
  --db-root-password <DB_ROOT_PASSWORD> \
  --admin-password <ADMIN_PASSWORD>

# Install apps in order
docker compose exec backend bench --site dev.example.com install-app erpnext
docker compose exec backend bench --site dev.example.com install-app hrms
docker compose exec backend bench --site dev.example.com install-app ipstc
docker compose exec backend bench --site dev.example.com install-app ipstc_hrms
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
docker compose exec backend bench --site dev.example.com migrate
```

To deploy a specific commit instead of the latest:

```bash
# Edit .env and set CUSTOM_TAG to the commit SHA shown in the Actions run
CUSTOM_TAG=abc1234def docker compose pull
docker compose up -d --remove-orphans
docker compose exec backend bench --site dev.example.com migrate
```

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

## Secrets summary

| Secret | Scope | Purpose |
|---|---|---|
| `APPS_PAT` | Repository | Clone private ipstc + ipstc-hrms during build |