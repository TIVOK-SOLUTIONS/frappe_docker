#!/usr/bin/env bash
set -euo pipefail

# ─── CONFIGURATION ──────────────────────────────────────────────────
SITE_DOMAIN="erp.tivoksolutions.com"
TRAEFIK_DOMAIN="traefik.tivoksolutions.com"
LE_EMAIL="admin@tivoksolutions.com"
DB_PASSWORD="your_secure_db_password"
ADMIN_PASSWORD="your_secure_admin_password"
TRAEFIK_PASSWORD="your_secure_traefik_password"
GITHUB_TOKEN="ghp_your_actual_token_here"

IMAGE_NAME="tivok"
IMAGE_TAG="v16"

COMPANY_NAME="TIVOK Solutions"
COMPANY_ABBR="TS"
COUNTRY="Kenya"
CURRENCY="KES"
TIMEZONE="Africa/Nairobi"
# ────────────────────────────────────────────────────────────────────

GITOPS_DIR="$HOME/gitops"
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok() { echo -e "${GREEN}[OK]${NC} $*"; }

# Step 1: Build Image with Token Injection
info "Building Image..."
TMP_APPS=$(mktemp /tmp/apps.XXXXXX.json)
python3 - "$GITHUB_TOKEN" <<'PYEOF'
import json, sys, os
token = sys.argv[1]
with open('app.json') as f:
    apps = json.load(f)
for app in apps:
    url = app.get('url', '')
    if 'github.com' in url:
        app['url'] = url.replace('https://github.com/', f'https://{token}@github.com/')
with open(os.environ['TMP_APPS'], 'w') as f:
    json.dump(apps, f, indent=2)
PYEOF

export TMP_APPS
docker build \
  --build-arg=FRAPPE_PATH=https://github.com/frappe/frappe \
  --build-arg=FRAPPE_BRANCH=version-16 \
  --build-arg=APPS_JSON_BASE64=$(base64 -w 0 "$TMP_APPS") \
  --tag="${IMAGE_NAME}:${IMAGE_TAG}" \
  --file=images/layered/Containerfile .

# Step 2: Infrastructure Configuration
mkdir -p "$GITOPS_DIR"
HASHED_PW=$(openssl passwd -apr1 "$TRAEFIK_PASSWORD")

echo "TRAEFIK_DOMAIN=${TRAEFIK_DOMAIN}" > "$GITOPS_DIR/traefik.env"
echo "EMAIL=${LE_EMAIL}" >> "$GITOPS_DIR/traefik.env"
printf "HASHED_PASSWORD='%s'\n" "$HASHED_PW" >> "$GITOPS_DIR/traefik.env"

cat > "$GITOPS_DIR/erpnext.env" <<EOF
CUSTOM_IMAGE=${IMAGE_NAME}
CUSTOM_TAG=${IMAGE_TAG}
PULL_POLICY=missing
DB_PASSWORD=${DB_PASSWORD}
SITES_RULE=Host(\`${SITE_DOMAIN}\`)
ROUTER=erpnext
BENCH_NETWORK=erpnext
LETSENCRYPT_EMAIL=${LE_EMAIL}
EOF

# Step 3: Deployment
docker compose --project-name traefik -f overrides/compose.traefik.yaml -f overrides/compose.traefik-ssl.yaml --env-file "$GITOPS_DIR/traefik.env" up -d

docker compose --project-name erpnext --env-file "$GITOPS_DIR/erpnext.env" \
  -f compose.yaml -f overrides/compose.redis.yaml -f overrides/compose.postgres.yaml \
  -f overrides/compose.multi-bench.yaml -f overrides/compose.multi-bench-ssl.yaml \
  config > "$GITOPS_DIR/erpnext.yaml"

docker compose --project-name erpnext -f "$GITOPS_DIR/erpnext.yaml" up -d

info "Waiting for DB..."
sleep 45

# Step 4: Site & App Installation
DC="docker compose --project-name erpnext -f $GITOPS_DIR/erpnext.yaml exec -T backend"
$DC bench new-site "${SITE_DOMAIN}" --db-type postgres --db-root-password "${DB_PASSWORD}" --admin-password "${ADMIN_PASSWORD}" --install-app erpnext

# Fix hyphenated folder names
info "Renaming folders..."
$DC sh -c "cd apps && [ -d ipstc-procurement ] && mv ipstc-procurement ipstc_procurement || true"
$DC sh -c "cd apps && [ -d ipstc-hrms ] && mv ipstc-hrms ipstc_hrms || true"

# Setup Wizard
info "Running Setup Wizard..."
SETUP_KWARGS=$(python3 -c "import json; print(json.dumps({'args': {'language':'English','country':'${COUNTRY}','timezone':'${TIMEZONE}','currency':'${CURRENCY}','full_name':'Administrator','email':'${LE_EMAIL}','company_name':'${COMPANY_NAME}','company_abbr':'${COMPANY_ABBR}','chart_of_accounts':'Standard'}}))")
$DC bench --site "${SITE_DOMAIN}" execute frappe.desk.page.setup_wizard.setup_wizard.setup_complete --kwargs "$SETUP_KWARGS"

# Install Apps
for APP in hrms ipstc ipstc_procurement ipstc_hrms; do
    info "Installing $APP..."
    $DC bench --site "${SITE_DOMAIN}" install-app $APP
done

ok "Done! Visit https://${SITE_DOMAIN}"
