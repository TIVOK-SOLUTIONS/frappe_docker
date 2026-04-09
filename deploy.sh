#!/usr/bin/env bash
# deploy.sh — Full production deployment of Frappe/ERPNext + HRMS + ipstc
#             HTTPS via Traefik + Let's Encrypt | PostgreSQL database
# Run from within the frappe_docker directory: bash deploy.sh
set -euo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }
banner() {
  echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${BLUE}  $*${NC}"
  echo -e "${BOLD}${BLUE}══════════════════════════════════════════════${NC}"
}

# ─── Preflight checks ────────────────────────────────────────────────────────
banner "Preflight"

[[ -f "compose.yaml" && -f "app.json" ]] || \
  die "Must be run from the frappe_docker directory (compose.yaml and app.json not found)."

command -v python3 &>/dev/null || die "python3 is required but not installed."
command -v openssl &>/dev/null || die "openssl is required but not installed."
command -v curl    &>/dev/null || die "curl is required but not installed."

ok "Directory check passed."

# ─── Collect inputs ──────────────────────────────────────────────────────────
banner "Configuration"

echo "Ensure DNS A records for both domains below already point to this server's IP."
echo "Let's Encrypt certificate issuance will fail otherwise."
echo

read -rp  "Site domain     [erp.tivoksolutions.com]:     " SITE_DOMAIN
SITE_DOMAIN="${SITE_DOMAIN:-erp.tivoksolutions.com}"

read -rp  "Traefik domain  [traefik.tivoksolutions.com]: " TRAEFIK_DOMAIN
TRAEFIK_DOMAIN="${TRAEFIK_DOMAIN:-traefik.tivoksolutions.com}"

read -rp  "Let's Encrypt email: " LE_EMAIL
[[ -n "$LE_EMAIL" ]] || die "Email is required."

echo
read -rsp "PostgreSQL root password: " DB_PASSWORD; echo
[[ -n "$DB_PASSWORD" ]] || die "DB password is required."
read -rsp "Confirm DB password:      " DB_PASSWORD2; echo
[[ "$DB_PASSWORD" == "$DB_PASSWORD2" ]] || die "Passwords do not match."

read -rsp "Frappe admin password:    " ADMIN_PASSWORD; echo
[[ -n "$ADMIN_PASSWORD" ]] || die "Admin password is required."
read -rsp "Confirm admin password:   " ADMIN_PASSWORD2; echo
[[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD2" ]] || die "Passwords do not match."

read -rsp "Traefik dashboard password: " TRAEFIK_PASSWORD; echo
[[ -n "$TRAEFIK_PASSWORD" ]] || die "Traefik password is required."

echo
read -rsp "GitHub Personal Access Token (for private app ipstc): " GITHUB_TOKEN; echo
[[ -n "$GITHUB_TOKEN" ]] || die "GitHub token is required."

# Fixed config
GITOPS_DIR="$HOME/gitops"
IMAGE_NAME="custom"
IMAGE_TAG="v16"

ok "Configuration collected."

# ─── Step 1/7: Install Docker ────────────────────────────────────────────────
banner "Step 1/7 — Install Docker"

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  ok "Docker already installed: $(docker --version)"
else
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sudo bash
  sudo usermod -aG docker "$USER"
  ok "Docker installed."
  echo
  warn "You have been added to the 'docker' group."
  warn "Please log out, log back in, and re-run this script."
  exit 0
fi

sudo systemctl enable docker --now 2>/dev/null || true

# ─── Step 2/7: Build custom image ────────────────────────────────────────────
banner "Step 2/7 — Build custom Docker image"

info "Creating temporary apps.json with GitHub token injected..."

TMP_APPS=$(mktemp /tmp/apps.XXXXXX.json)
trap 'rm -f "$TMP_APPS"' EXIT

python3 - "$GITHUB_TOKEN" <<'PYEOF'
import json, sys, os

token = sys.argv[1]
with open('app.json') as f:
    apps = json.load(f)

for app in apps:
    url = app.get('url', '')
    if 'TIVOK-SOLUTIONS' in url:
        app['url'] = url.replace('https://github.com/', f'https://{token}@github.com/')

with open(os.environ['TMP_APPS'], 'w') as f:
    json.dump(apps, f, indent=2)
PYEOF

export TMP_APPS
APPS_JSON_BASE64=$(base64 -w 0 "$TMP_APPS")

info "Building image ${IMAGE_NAME}:${IMAGE_TAG} — this will take several minutes..."

docker build \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --build-arg=APPS_JSON_BASE64="$APPS_JSON_BASE64" \
  --tag="${IMAGE_NAME}:${IMAGE_TAG}" \
  --file=images/layered/Containerfile .

ok "Image built: ${IMAGE_NAME}:${IMAGE_TAG}"

# ─── Step 3/7: Prepare gitops directory ──────────────────────────────────────
banner "Step 3/7 — Prepare gitops directory"

mkdir -p "$GITOPS_DIR"
ok "Directory ready: $GITOPS_DIR"

# ─── Step 4/7: Deploy Traefik with HTTPS ─────────────────────────────────────
banner "Step 4/7 — Deploy Traefik (HTTPS + Let's Encrypt)"

HASHED_PW=$(openssl passwd -apr1 "$TRAEFIK_PASSWORD")

{
  echo "TRAEFIK_DOMAIN=${TRAEFIK_DOMAIN}"
  echo "EMAIL=${LE_EMAIL}"
  printf "HASHED_PASSWORD='%s'\n" "$HASHED_PW"
} > "$GITOPS_DIR/traefik.env"

if docker compose --project-name traefik ps --quiet 2>/dev/null | grep -q .; then
  warn "Traefik is already running — skipping."
else
  docker compose --project-name traefik \
    --env-file "$GITOPS_DIR/traefik.env" \
    -f overrides/compose.traefik.yaml \
    -f overrides/compose.traefik-ssl.yaml \
    up -d
  ok "Traefik deployed with HTTPS."
fi

# ─── Step 5/7: Generate ERPNext + PostgreSQL compose file ────────────────────
banner "Step 5/7 — Configure ERPNext bench (PostgreSQL)"

# DB_HOST and DB_PORT are set by compose.postgres.yaml overlay (host=db, port=5432)
# DB_PASSWORD is used by the postgres overlay as POSTGRES_PASSWORD
cat > "$GITOPS_DIR/erpnext.env" <<EOF
ERPNEXT_VERSION=v16.10.1
CUSTOM_IMAGE=${IMAGE_NAME}
CUSTOM_TAG=${IMAGE_TAG}
PULL_POLICY=missing
DB_PASSWORD=${DB_PASSWORD}
SITES_RULE=Host(\`${SITE_DOMAIN}\`)
ROUTER=erpnext
BENCH_NETWORK=erpnext
LETSENCRYPT_EMAIL=${LE_EMAIL}
EOF

docker compose --project-name erpnext \
  --env-file "$GITOPS_DIR/erpnext.env" \
  -f compose.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.postgres.yaml \
  -f overrides/compose.multi-bench.yaml \
  -f overrides/compose.multi-bench-ssl.yaml \
  config > "$GITOPS_DIR/erpnext.yaml"

ok "Compose file generated: $GITOPS_DIR/erpnext.yaml"

# ─── Step 6/7: Deploy ERPNext bench ──────────────────────────────────────────
banner "Step 6/7 — Deploy ERPNext bench"

docker compose --project-name erpnext -f "$GITOPS_DIR/erpnext.yaml" up -d

info "Waiting for PostgreSQL to be healthy..."
for i in $(seq 1 40); do
  DB_CONTAINER=$(docker compose --project-name erpnext -f "$GITOPS_DIR/erpnext.yaml" ps -q db 2>/dev/null || echo "")
  if [[ -n "$DB_CONTAINER" ]]; then
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' "$DB_CONTAINER" 2>/dev/null || echo "")
    if [[ "$HEALTH" == "healthy" ]]; then
      ok "PostgreSQL is healthy."
      break
    fi
  fi
  if [[ $i -eq 40 ]]; then
    die "PostgreSQL did not become healthy in time. Check: docker compose --project-name erpnext logs db"
  fi
  sleep 3
done

info "Waiting for configurator to complete..."
CONFIGURATOR_ID=$(docker compose --project-name erpnext -f "$GITOPS_DIR/erpnext.yaml" ps -q configurator 2>/dev/null || echo "")
if [[ -n "$CONFIGURATOR_ID" ]]; then
  EXIT_CODE=$(docker wait "$CONFIGURATOR_ID")
  [[ "$EXIT_CODE" == "0" ]] || \
    die "Configurator failed (exit code $EXIT_CODE). Check: docker logs $CONFIGURATOR_ID"
  ok "Configurator finished successfully."
else
  warn "Configurator container not found — it may have already completed."
fi

# ─── Step 7/7: Create site and install apps ───────────────────────────────────
banner "Step 7/7 — Create site and install apps"

DC="docker compose --project-name erpnext -f $GITOPS_DIR/erpnext.yaml exec -T backend"

info "Creating site: ${SITE_DOMAIN}"
$DC bench new-site "${SITE_DOMAIN}" \
  --db-type postgres \
  --db-root-password "${DB_PASSWORD}" \
  --admin-password "${ADMIN_PASSWORD}" \
  --install-app erpnext

info "Installing HRMS..."
$DC bench --site "${SITE_DOMAIN}" install-app hrms

info "Installing ipstc..."
$DC bench --site "${SITE_DOMAIN}" install-app ipstc

info "Setting default site..."
$DC bench use "${SITE_DOMAIN}"

# ─── Done ────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Deployment complete!${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════${NC}"
echo
echo -e "  Site URL        : ${BOLD}https://${SITE_DOMAIN}${NC}"
echo -e "  Traefik UI      : ${BOLD}https://${TRAEFIK_DOMAIN}${NC}  (user: admin)"
echo -e "  Frappe login    : ${BOLD}Administrator${NC}"
echo
echo -e "  Database        : ${BOLD}PostgreSQL (bundled)${NC}"
echo -e "  Installed apps  : ${BOLD}frappe, erpnext, hrms, ipstc${NC}"
echo
warn "Store your passwords securely — they will not be shown again."
warn "Env files are saved in: $GITOPS_DIR"