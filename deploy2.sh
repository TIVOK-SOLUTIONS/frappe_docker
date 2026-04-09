#!/usr/bin/env bash
# deploy2.sh — Production deployment: Frappe/ERPNext + HRMS + ipstc
#              HTTPS via Traefik + Let's Encrypt | PostgreSQL
# Run from within the frappe_docker directory: bash deploy2.sh
set -euo pipefail

# ══════════════════════════════════════════════════════════════════
#  CONFIGURATION — edit these values before running
# ══════════════════════════════════════════════════════════════════

SITE_DOMAIN="erp.tivoksolutions.com"       # Your ERPNext site domain
TRAEFIK_DOMAIN="traefik.tivoksolutions.com" # Traefik dashboard domain
LE_EMAIL="admin@tivoksolutions.com"         # Let's Encrypt email

DB_PASSWORD="changeme_db"                  # PostgreSQL root password
ADMIN_PASSWORD="changeme_admin"            # Frappe Administrator password
TRAEFIK_PASSWORD="changeme_traefik"        # Traefik dashboard password

GITHUB_TOKEN="ghp_xxxxxxxxxxxxxxxxxxxx"    # GitHub PAT for private repo

# Image settings — these link the build to the compose deployment
IMAGE_NAME="tivok"    # Name for the custom Docker image
IMAGE_TAG="v16"       # Tag for the custom Docker image

# Company setup — automatically completes the ERPNext setup wizard
COMPANY_NAME="TIVOK Solutions"   # First company name
COMPANY_ABBR="TS"                # Company abbreviation (2-4 chars)
COUNTRY="Kenya"                  # Country (must match ERPNext country list)
CURRENCY="KES"                   # Default currency code
TIMEZONE="Africa/Nairobi"        # Timezone (IANA format)
CHART_OF_ACCOUNTS="Standard"     # Chart of accounts template

# ══════════════════════════════════════════════════════════════════
#  END OF CONFIGURATION
# ══════════════════════════════════════════════════════════════════

# ─── Colors ──────────────────────────────────────────────────────
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

GITOPS_DIR="$HOME/gitops"

# ─── Preflight ───────────────────────────────────────────────────
banner "Preflight"

[[ -f "compose.yaml" && -f "app.json" ]] || \
  die "Must be run from the frappe_docker directory."

command -v python3 &>/dev/null || die "python3 is required."
command -v openssl &>/dev/null || die "openssl is required."
command -v curl    &>/dev/null || die "curl is required."

# Block accidental run with placeholder values
[[ "$GITHUB_TOKEN" != "ghp_xxxxxxxxxxxxxxxxxxxx" ]] || \
  die "Set your real GITHUB_TOKEN at the top of this script before running."
[[ "$DB_PASSWORD" != "changeme_db" ]] || \
  die "Set a real DB_PASSWORD at the top of this script before running."
[[ "$ADMIN_PASSWORD" != "changeme_admin" ]] || \
  die "Set a real ADMIN_PASSWORD at the top of this script before running."

ok "Preflight passed."

# ─── Step 1/7: Install Docker ────────────────────────────────────
banner "Step 1/7 — Install Docker"

if command -v docker &>/dev/null && docker compose version &>/dev/null; then
  ok "Docker already installed: $(docker --version)"
else
  info "Installing Docker..."
  curl -fsSL https://get.docker.com | sudo bash
  sudo usermod -aG docker "$USER"
  warn "Added to 'docker' group. Log out, log back in, then re-run this script."
  exit 0
fi

sudo systemctl enable docker --now 2>/dev/null || true

# ─── Step 2/7: Build custom image ────────────────────────────────
banner "Step 2/7 — Build custom Docker image"

# How image naming works:
#   docker build  --tag ${IMAGE_NAME}:${IMAGE_TAG}     ← builds and names the image
#   erpnext.env   CUSTOM_IMAGE=${IMAGE_NAME}           ← tells compose which image to use
#                 CUSTOM_TAG=${IMAGE_TAG}              ← tells compose which tag to use
#                 PULL_POLICY=missing                  ← use local image, don't try to pull

info "Injecting GitHub token into app.json for build..."
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

info "Building ${IMAGE_NAME}:${IMAGE_TAG} — this will take several minutes..."
docker build \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --build-arg=APPS_JSON_BASE64="$APPS_JSON_BASE64" \
  --tag="${IMAGE_NAME}:${IMAGE_TAG}" \
  --file=images/layered/Containerfile .

ok "Image built successfully: ${IMAGE_NAME}:${IMAGE_TAG}"
docker images "${IMAGE_NAME}:${IMAGE_TAG}"

# ─── Step 3/7: Prepare gitops directory ──────────────────────────
banner "Step 3/7 — Prepare gitops directory"

mkdir -p "$GITOPS_DIR"
ok "Directory ready: $GITOPS_DIR"

# ─── Step 4/7: Deploy Traefik with HTTPS ─────────────────────────
banner "Step 4/7 — Deploy Traefik (HTTPS + Let's Encrypt)"

HASHED_PW=$(openssl passwd -apr1 "$TRAEFIK_PASSWORD")

{
  echo "TRAEFIK_DOMAIN=${TRAEFIK_DOMAIN}"
  echo "EMAIL=${LE_EMAIL}"
  printf "HASHED_PASSWORD='%s'\n" "$HASHED_PW"
} > "$GITOPS_DIR/traefik.env"

info "Traefik env written to $GITOPS_DIR/traefik.env"

if docker compose --project-name traefik ps --quiet 2>/dev/null | grep -q .; then
  warn "Traefik is already running — skipping."
else
  docker compose --project-name traefik \
    --env-file "$GITOPS_DIR/traefik.env" \
    -f overrides/compose.traefik.yaml \
    -f overrides/compose.traefik-ssl.yaml \
    up -d
  ok "Traefik deployed."
fi

# ─── Step 5/7: Generate ERPNext env + compose file ───────────────
banner "Step 5/7 — Configure ERPNext bench (PostgreSQL)"

# What each variable does in erpnext.env:
#
#   CUSTOM_IMAGE   — image name you used in 'docker build --tag'
#   CUSTOM_TAG     — image tag you used in 'docker build --tag'
#   PULL_POLICY    — 'missing' means use local image, never pull from registry
#   DB_PASSWORD    — PostgreSQL POSTGRES_PASSWORD (set by compose.postgres.yaml)
#   SITES_RULE     — Traefik routing rule matching your domain
#   ROUTER         — unique name for Traefik router labels
#   BENCH_NETWORK  — internal Docker network name for this bench
#
#   DB_HOST and DB_PORT are NOT set here — compose.postgres.yaml
#   automatically sets DB_HOST=db and DB_PORT=5432 inside the container.

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

info "ERPNext env written to $GITOPS_DIR/erpnext.env"
info "Contents:"
cat "$GITOPS_DIR/erpnext.env"

# Merge all compose files into a single resolved yaml
docker compose --project-name erpnext \
  --env-file "$GITOPS_DIR/erpnext.env" \
  -f compose.yaml \
  -f overrides/compose.redis.yaml \
  -f overrides/compose.postgres.yaml \
  -f overrides/compose.multi-bench.yaml \
  -f overrides/compose.multi-bench-ssl.yaml \
  config > "$GITOPS_DIR/erpnext.yaml"

ok "Compose file generated: $GITOPS_DIR/erpnext.yaml"

# ─── Step 6/7: Deploy ERPNext bench ──────────────────────────────
banner "Step 6/7 — Deploy ERPNext bench"

docker compose --project-name erpnext -f "$GITOPS_DIR/erpnext.yaml" up -d

info "Waiting for PostgreSQL to be healthy..."
for i in $(seq 1 40); do
  DB_CONTAINER=$(docker compose --project-name erpnext \
    -f "$GITOPS_DIR/erpnext.yaml" ps -q db 2>/dev/null || echo "")
  if [[ -n "$DB_CONTAINER" ]]; then
    HEALTH=$(docker inspect --format='{{.State.Health.Status}}' \
      "$DB_CONTAINER" 2>/dev/null || echo "")
    if [[ "$HEALTH" == "healthy" ]]; then
      ok "PostgreSQL is healthy."
      break
    fi
  fi
  [[ $i -lt 40 ]] || die "PostgreSQL health check timed out. Run: docker compose --project-name erpnext logs db"
  sleep 3
done

info "Waiting for configurator to complete..."
CONFIGURATOR_ID=$(docker compose --project-name erpnext \
  -f "$GITOPS_DIR/erpnext.yaml" ps -q configurator 2>/dev/null || echo "")
if [[ -n "$CONFIGURATOR_ID" ]]; then
  EXIT_CODE=$(docker wait "$CONFIGURATOR_ID")
  [[ "$EXIT_CODE" == "0" ]] || \
    die "Configurator failed (exit $EXIT_CODE). Run: docker logs $CONFIGURATOR_ID"
  ok "Configurator finished."
else
  warn "Configurator already completed."
fi

# ─── Step 7/7: Create site and install apps ──────────────────────
banner "Step 7/7 — Create site and install apps"

DC="docker compose --project-name erpnext -f $GITOPS_DIR/erpnext.yaml exec -T backend"

info "Creating site ${SITE_DOMAIN} with ERPNext..."
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

info "Completing setup wizard (creates company: ${COMPANY_NAME})..."

# Build the setup wizard args as JSON using python3 to handle special characters safely
SETUP_KWARGS=$(python3 -c "
import json
print(json.dumps({
    'args': {
        'language':           'English',
        'country':            '${COUNTRY}',
        'timezone':           '${TIMEZONE}',
        'currency':           '${CURRENCY}',
        'full_name':          'Administrator',
        'email':              '${LE_EMAIL}',
        'company_name':       '${COMPANY_NAME}',
        'company_abbr':       '${COMPANY_ABBR}',
        'chart_of_accounts':  '${CHART_OF_ACCOUNTS}'
    }
}))
")

$DC bench --site "${SITE_DOMAIN}" execute \
  frappe.desk.page.setup_wizard.setup_wizard.setup_complete \
  --kwargs "$SETUP_KWARGS"

ok "Company '${COMPANY_NAME}' created and setup wizard complete."

# ─── Done ────────────────────────────────────────────────────────
echo
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════${NC}"
echo -e "${GREEN}${BOLD}  Deployment complete!${NC}"
echo -e "${GREEN}${BOLD}══════════════════════════════════════════════${NC}"
echo
echo -e "  Site URL        : ${BOLD}https://${SITE_DOMAIN}${NC}"
echo -e "  Traefik UI      : ${BOLD}https://${TRAEFIK_DOMAIN}${NC}  (user: admin)"
echo -e "  Frappe login    : ${BOLD}Administrator${NC}"
echo -e "  Database        : ${BOLD}PostgreSQL${NC}"
echo -e "  Docker image    : ${BOLD}${IMAGE_NAME}:${IMAGE_TAG}${NC}"
echo -e "  Installed apps  : ${BOLD}frappe, erpnext, hrms, ipstc${NC}"
echo -e "  Company         : ${BOLD}${COMPANY_NAME} (${COMPANY_ABBR})${NC}"
echo -e "  Country/Currency: ${BOLD}${COUNTRY} / ${CURRENCY}${NC}"
echo
warn "Env files (with passwords) are in: $GITOPS_DIR"
