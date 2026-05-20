#!/usr/bin/env bash
###############################################################################
# Wardian Edge — One-Command Installer
#
# Prerequisites: docker, curl, openssl (NO Python needed on host)
#
# Delivered as a tarball containing:
#   install.sh, docker-compose.yml, init.sql, DEPLOYMENT-RUNBOOK.md
#
# Usage:
#   bash install.sh --token <ORG_TOKEN> --ghcr <GHCR_TOKEN> --llm-key <API_KEY>
#
# Options:
#   --token       Gateway org token (from Wardian admin dashboard)
#   --ghcr        GitHub token with read:packages scope (to pull images)
#   --llm-key     LLM API key (any OpenAI-compatible provider)
#   --llm-url     LLM base URL (default: https://llm.chutes.ai/v1)
#   --cloud-url   Cloud WebSocket URL (default: wss://app.wardian.ai/ws/gateway)
#   --mcps        Comma-separated optional MCPs: gmail,drive,calendar,sheets,
#                 docs,github,pharmacy,pipedrive,erplain,pennylane
#   --google-sa-key      Path to Google service account JSON
#   --google-client-id   Google OAuth client ID
#   --google-client-secret Google OAuth client secret
#   --drive-user         Google Workspace admin email (service_account mode)
#   --pipedrive-token    Pipedrive API token
#   --pipedrive-domain   Pipedrive company domain
#   --erplain-token      Erplain API token
#   --pennylane-token    Pennylane API token
#   --ms-tenant-id       Microsoft 365 Azure tenant ID
#   --ms-client-id       Microsoft 365 Azure client ID
#   --ms-client-secret   Microsoft 365 Azure client secret
#   --dir         Install directory (default: ./wardian-edge)
#   -y            Skip confirmation prompt
#   --help        Show this help
#
# Example:
#   bash install.sh \
#     --token wdn_gw_abc123 \
#     --ghcr ghp_xxx \
#     --llm-key cpk_xxx \
#     --mcps gmail,drive,pipedrive \
#     --google-sa-key ~/service-account.json \
#     --drive-user admin@company.com \
#     --pipedrive-token xxx \
#     --pipedrive-domain acme
###############################################################################

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- Colors -----------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------- Parse arguments --------------------------------------------------
ORG_TOKEN=""
GHCR_TOKEN=""
LLM_API_KEY=""
OFFLINE=false
LLM_BASE_URL="https://llm.chutes.ai/v1"
CLOUD_URL="wss://app.wardian-ai.com"
INSTALL_DIR="./wardian-edge"
MCPS=""
GMAIL_AUTH_MODE="oauth"
GOOGLE_CLIENT_ID=""
GOOGLE_CLIENT_SECRET=""
GOOGLE_SERVICE_ACCOUNT_KEY_PATH=""
GOOGLE_SERVICE_ACCOUNT_KEY=""
DRIVE_TARGET_USER=""
PIPEDRIVE_API_TOKEN=""
PIPEDRIVE_COMPANY_DOMAIN=""
ERPLAIN_API_TOKEN=""
PENNYLANE_API_TOKEN=""
MS365_TENANT_ID=""
MS365_CLIENT_ID=""
MS365_CLIENT_SECRET=""
AUTO_YES=false

show_help() {
    head -40 "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)     ORG_TOKEN="$2"; shift 2 ;;
        --ghcr)      GHCR_TOKEN="$2"; shift 2 ;;
        --llm-key)   LLM_API_KEY="$2"; shift 2 ;;
        --llm-url)   LLM_BASE_URL="$2"; shift 2 ;;
        --cloud-url) CLOUD_URL="$2"; shift 2 ;;
        --mcps)      MCPS="$2"; shift 2 ;;
        --google-sa-key)     GOOGLE_SERVICE_ACCOUNT_KEY_PATH="$2"; shift 2 ;;
        --google-client-id)  GOOGLE_CLIENT_ID="$2"; shift 2 ;;
        --google-client-secret) GOOGLE_CLIENT_SECRET="$2"; shift 2 ;;
        --drive-user)        DRIVE_TARGET_USER="$2"; shift 2 ;;
        --pipedrive-token)   PIPEDRIVE_API_TOKEN="$2"; shift 2 ;;
        --pipedrive-domain)  PIPEDRIVE_COMPANY_DOMAIN="$2"; shift 2 ;;
        --erplain-token)     ERPLAIN_API_TOKEN="$2"; shift 2 ;;
        --pennylane-token)   PENNYLANE_API_TOKEN="$2"; shift 2 ;;
        --ms-tenant-id)      MS365_TENANT_ID="$2"; shift 2 ;;
        --ms-client-id)      MS365_CLIENT_ID="$2"; shift 2 ;;
        --ms-client-secret)  MS365_CLIENT_SECRET="$2"; shift 2 ;;
        --dir)       INSTALL_DIR="$2"; shift 2 ;;
        --offline)   OFFLINE=true; shift ;;
        -y)          AUTO_YES=true; shift ;;
        --help|-h)   show_help ;;
        *)           err "Unknown option: $1. Use --help for usage." ;;
    esac
done

# ---------- Validate required args ------------------------------------------
[[ -z "$ORG_TOKEN" ]]    && err "Missing --token (gateway org token from admin dashboard)"
[[ -z "$LLM_API_KEY" ]]  && err "Missing --llm-key (LLM API key)"
if [[ "$OFFLINE" != "true" && -z "$GHCR_TOKEN" ]]; then
    err "Missing --ghcr (GitHub token) — or use --offline if images are pre-loaded with 'docker load'"
fi

# ---------- Parse MCP selection ----------------------------------------------
ENABLE_GMAIL_MCP=false
ENABLE_DRIVE_MCP=false
ENABLE_CALENDAR_MCP=false
ENABLE_SHEETS_MCP=false
ENABLE_DOCS_MCP=false
ENABLE_GITHUB_MCP=false
ENABLE_PHARMACY_MCP=false
ENABLE_PIPEDRIVE_MCP=false
ENABLE_ERPLAIN_MCP=false
ENABLE_PENNYLANE_MCP=false
ENABLE_MICROSOFT365_MCP=false

if [[ -n "$MCPS" ]]; then
    IFS=',' read -ra MCP_LIST <<< "$MCPS"
    for mcp in "${MCP_LIST[@]}"; do
        case "$(echo "$mcp" | tr -d ' ' | tr '[:upper:]' '[:lower:]')" in
            gmail)     ENABLE_GMAIL_MCP=true ;;
            drive)     ENABLE_DRIVE_MCP=true ;;
            calendar)  ENABLE_CALENDAR_MCP=true ;;
            sheets)    ENABLE_SHEETS_MCP=true ;;
            docs)      ENABLE_DOCS_MCP=true ;;
            github)    ENABLE_GITHUB_MCP=true ;;
            pharmacy)  ENABLE_PHARMACY_MCP=true ;;
            pipedrive) ENABLE_PIPEDRIVE_MCP=true ;;
            erplain)   ENABLE_ERPLAIN_MCP=true ;;
            pennylane)     ENABLE_PENNYLANE_MCP=true ;;
            microsoft365)  ENABLE_MICROSOFT365_MCP=true ;;
            *)             warn "Unknown MCP: $mcp (ignored)" ;;
        esac
    done
fi

# Determine Google auth mode
NEEDS_GOOGLE=false
if [[ "$ENABLE_GMAIL_MCP" == "true" || "$ENABLE_DRIVE_MCP" == "true" || \
      "$ENABLE_CALENDAR_MCP" == "true" || "$ENABLE_SHEETS_MCP" == "true" || \
      "$ENABLE_DOCS_MCP" == "true" ]]; then
    NEEDS_GOOGLE=true
fi

if [[ "$NEEDS_GOOGLE" == "true" ]]; then
    if [[ -n "$GOOGLE_SERVICE_ACCOUNT_KEY_PATH" ]]; then
        GMAIL_AUTH_MODE=service_account
        [[ ! -f "$GOOGLE_SERVICE_ACCOUNT_KEY_PATH" ]] && err "Service account file not found: $GOOGLE_SERVICE_ACCOUNT_KEY_PATH"
    elif [[ -n "$GOOGLE_CLIENT_ID" && -n "$GOOGLE_CLIENT_SECRET" ]]; then
        GMAIL_AUTH_MODE=oauth
    else
        err "Google MCPs enabled but no credentials. Use --google-sa-key or --google-client-id + --google-client-secret"
    fi
fi

[[ "$ENABLE_DRIVE_MCP" == "true" && "$GMAIL_AUTH_MODE" == "service_account" && -z "$DRIVE_TARGET_USER" ]] && \
    err "Drive + service account requires --drive-user"
[[ "$ENABLE_PIPEDRIVE_MCP" == "true" && -z "$PIPEDRIVE_API_TOKEN" ]] && err "Pipedrive enabled but --pipedrive-token missing"
[[ "$ENABLE_PIPEDRIVE_MCP" == "true" && -z "$PIPEDRIVE_COMPANY_DOMAIN" ]] && err "Pipedrive enabled but --pipedrive-domain missing"
[[ "$ENABLE_ERPLAIN_MCP" == "true" && -z "$ERPLAIN_API_TOKEN" ]] && err "Erplain enabled but --erplain-token missing"
[[ "$ENABLE_PENNYLANE_MCP" == "true" && -z "$PENNYLANE_API_TOKEN" ]] && err "Pennylane enabled but --pennylane-token missing"
[[ "$ENABLE_MICROSOFT365_MCP" == "true" && -z "$MS365_TENANT_ID" ]] && err "Microsoft 365 enabled but --ms-tenant-id missing"
[[ "$ENABLE_MICROSOFT365_MCP" == "true" && -z "$MS365_CLIENT_ID" ]] && err "Microsoft 365 enabled but --ms-client-id missing"
[[ "$ENABLE_MICROSOFT365_MCP" == "true" && -z "$MS365_CLIENT_SECRET" ]] && err "Microsoft 365 enabled but --ms-client-secret missing"

# ---------- Pre-flight checks -----------------------------------------------
echo ""
echo -e "${BOLD}=============================================${NC}"
echo -e "${BOLD}   WARDIAN EDGE — Installer${NC}"
echo -e "${BOLD}=============================================${NC}"
echo ""

info "Checking prerequisites..."

for cmd in docker curl openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        err "$cmd is not installed. Install it and retry."
    fi
done

if ! docker compose version &>/dev/null; then
    err "Docker Compose v2 not found. Update Docker or install the compose plugin."
fi

ok "Prerequisites OK (docker, docker compose, curl, openssl)"

# ---------- Show plan --------------------------------------------------------
echo ""
info "Deployment plan:"
echo ""
echo "  Install dir:   $INSTALL_DIR"
echo "  Cloud URL:     $CLOUD_URL"
echo "  Org token:     ${ORG_TOKEN:0:16}..."
echo "  LLM provider:  $LLM_BASE_URL"
echo ""
echo "  Services:"
echo "    - PostgreSQL (pgvector)"
echo "    - MinIO (object storage)"
echo "    - MCP Servers (database, memory)"
echo "    - Knowledge Engine (RAG)"
echo "    - Gateway (WebSocket relay)"

ENABLED_MCPS=""
[[ "$ENABLE_GMAIL_MCP" == "true" ]]     && ENABLED_MCPS="${ENABLED_MCPS} gmail"
[[ "$ENABLE_DRIVE_MCP" == "true" ]]     && ENABLED_MCPS="${ENABLED_MCPS} drive"
[[ "$ENABLE_CALENDAR_MCP" == "true" ]]  && ENABLED_MCPS="${ENABLED_MCPS} calendar"
[[ "$ENABLE_SHEETS_MCP" == "true" ]]    && ENABLED_MCPS="${ENABLED_MCPS} sheets"
[[ "$ENABLE_DOCS_MCP" == "true" ]]      && ENABLED_MCPS="${ENABLED_MCPS} docs"
[[ "$ENABLE_GITHUB_MCP" == "true" ]]    && ENABLED_MCPS="${ENABLED_MCPS} github"
[[ "$ENABLE_PHARMACY_MCP" == "true" ]]  && ENABLED_MCPS="${ENABLED_MCPS} pharmacy"
[[ "$ENABLE_PIPEDRIVE_MCP" == "true" ]] && ENABLED_MCPS="${ENABLED_MCPS} pipedrive"
[[ "$ENABLE_ERPLAIN_MCP" == "true" ]]   && ENABLED_MCPS="${ENABLED_MCPS} erplain"
[[ "$ENABLE_PENNYLANE_MCP" == "true" ]]     && ENABLED_MCPS="${ENABLED_MCPS} pennylane"
[[ "$ENABLE_MICROSOFT365_MCP" == "true" ]] && ENABLED_MCPS="${ENABLED_MCPS} microsoft365"

if [[ -n "$ENABLED_MCPS" ]]; then
    echo "    - Optional MCPs:${ENABLED_MCPS}"
fi

echo ""

if [[ "$AUTO_YES" != "true" ]]; then
    read -rp "$(echo -e "${CYAN}Proceed? [Y/n]:${NC} ")" CONFIRM
    case "${CONFIRM:-y}" in
        [yY]|[yY]es|"") ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# ---------- Login to ghcr.io ------------------------------------------------
if [[ "$OFFLINE" != "true" ]]; then
    info "Logging in to ghcr.io..."
    echo "$GHCR_TOKEN" | docker login ghcr.io -u wardian-client --password-stdin 2>/dev/null \
        || err "Failed to login to ghcr.io. Check your --ghcr token."
    ok "Logged in to ghcr.io"
else
    info "Offline mode — skipping ghcr.io login"
fi

# ---------- Create install directory -----------------------------------------
mkdir -p "$INSTALL_DIR/config"

# Copy docker-compose.yml and init.sql from the tarball (same directory as this script)
if [[ -f "$SCRIPT_DIR/docker-compose.yml" ]]; then
    cp "$SCRIPT_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"
    ok "docker-compose.yml copied"
else
    err "docker-compose.yml not found next to install.sh. Ensure you extracted the full tarball."
fi

if [[ -f "$SCRIPT_DIR/init.sql" ]]; then
    cp "$SCRIPT_DIR/init.sql" "$INSTALL_DIR/init.sql"
    ok "init.sql copied"
else
    err "init.sql not found next to install.sh. Ensure you extracted the full tarball."
fi

cd "$INSTALL_DIR"

# ---------- Generate credentials (openssl only, no Python) -------------------
info "Generating secure credentials..."
POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
MINIO_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
# Fernet key = url-safe base64 of 32 random bytes (44 chars with trailing =)
INTEGRATION_ENCRYPTION_KEY=$(openssl rand 32 | openssl base64 -A | tr '+/' '-_')
# Bearer key shared by mcp-servers, knowledge, gateway to authenticate
# HTTP calls between components on the local Docker network. Starts in
# warn mode (logs but doesn't block) so a fresh install can't break on
# a config typo; flip MCP_AUTH_MODE=enforce in .env once logs are clean.
MCP_API_KEY=$(openssl rand -hex 32)
ok "Credentials generated (POSTGRES_PASSWORD, MINIO_ROOT_PASSWORD, INTEGRATION_ENCRYPTION_KEY, MCP_API_KEY)"

# ---------- Copy Google service account if provided ---------------------------
if [[ -n "$GOOGLE_SERVICE_ACCOUNT_KEY_PATH" ]]; then
    cp "$GOOGLE_SERVICE_ACCOUNT_KEY_PATH" config/google-service-account.json
    GOOGLE_SERVICE_ACCOUNT_KEY="/app/config/google-service-account.json"
    ok "Google service account copied to config/"
else
    echo '{}' > config/google-service-account.json
fi

# ---------- Write .env -------------------------------------------------------
info "Writing .env..."
cat > .env <<ENVEOF
# Wardian Edge — generated by install.sh on $(date -Iseconds)
EDGE_MODE=onprem

# Gateway
ORG_TOKEN=$ORG_TOKEN
CLOUD_URL=$CLOUD_URL

# LLM (any OpenAI-compatible endpoint)
LLM_API_KEY=$LLM_API_KEY
LLM_BASE_URL=$LLM_BASE_URL

# PostgreSQL
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# MinIO
MINIO_ROOT_USER=wardian
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD

# MCP Servers
ENABLE_GMAIL_MCP=$ENABLE_GMAIL_MCP
ENABLE_DRIVE_MCP=$ENABLE_DRIVE_MCP
ENABLE_CALENDAR_MCP=$ENABLE_CALENDAR_MCP
ENABLE_SHEETS_MCP=$ENABLE_SHEETS_MCP
ENABLE_DOCS_MCP=$ENABLE_DOCS_MCP
ENABLE_GITHUB_MCP=$ENABLE_GITHUB_MCP
ENABLE_PHARMACY_MCP=$ENABLE_PHARMACY_MCP
ENABLE_PIPEDRIVE_MCP=$ENABLE_PIPEDRIVE_MCP
ENABLE_ERPLAIN_MCP=$ENABLE_ERPLAIN_MCP
ENABLE_PENNYLANE_MCP=$ENABLE_PENNYLANE_MCP
ENABLE_MICROSOFT365_MCP=$ENABLE_MICROSOFT365_MCP
ENABLE_MICROSOFT365=$ENABLE_MICROSOFT365_MCP

# Microsoft 365
MICROSOFT_TENANT_ID=$MS365_TENANT_ID
MICROSOFT_CLIENT_ID=$MS365_CLIENT_ID
MICROSOFT_CLIENT_SECRET=$MS365_CLIENT_SECRET
MICROSOFT_AUTH_MODE=client_credentials

# Google Workspace
GMAIL_AUTH_MODE=$GMAIL_AUTH_MODE
GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID
GOOGLE_CLIENT_SECRET=$GOOGLE_CLIENT_SECRET
GOOGLE_SERVICE_ACCOUNT_KEY=$GOOGLE_SERVICE_ACCOUNT_KEY
DRIVE_TARGET_USER=$DRIVE_TARGET_USER

# Pipedrive
PIPEDRIVE_API_TOKEN=$PIPEDRIVE_API_TOKEN
PIPEDRIVE_COMPANY_DOMAIN=$PIPEDRIVE_COMPANY_DOMAIN

# Erplain
ERPLAIN_API_TOKEN=$ERPLAIN_API_TOKEN

# Pennylane
PENNYLANE_API_TOKEN=$PENNYLANE_API_TOKEN

# Encryption
INTEGRATION_ENCRYPTION_KEY=$INTEGRATION_ENCRYPTION_KEY

# MCP bearer auth — shared by mcp-servers (validates), knowledge + gateway (send the header).
# Mode: warn = log only, enforce = 401/403, off = disabled.
MCP_API_KEY=$MCP_API_KEY
MCP_AUTH_MODE=warn

# Auto-update (Watchtower)
GHCR_TOKEN=$GHCR_TOKEN
WATCHTOWER_POLL_INTERVAL=21600
ENVEOF
ok ".env written"

# ---------- Write config/edge.yaml ------------------------------------------
info "Writing config/edge.yaml..."
{
    echo "org_token: \"$ORG_TOKEN\""
    echo "cloud_url: \"$CLOUD_URL\""
    echo ""
    echo "servers:"
    echo "  database:"
    echo "    url: \"http://mcp-servers:8001/sse\""
    echo "  memory:"
    echo "    url: \"http://mcp-servers:8002/sse\""

    [[ "$ENABLE_GMAIL_MCP" == "true" ]] && {
        echo "  gmail:"
        echo "    url: \"http://mcp-servers:8003/sse\""
        echo "    auth: user"
        echo "    provider: google"
    }
    [[ "$ENABLE_DRIVE_MCP" == "true" ]] && {
        echo "  drive:"
        echo "    url: \"http://mcp-servers:8004/sse\""
        echo "    auth: user"
        echo "    provider: google"
    }
    [[ "$ENABLE_GITHUB_MCP" == "true" ]] && {
        echo "  github:"
        echo "    url: \"http://mcp-servers:8005/sse\""
    }
    [[ "$ENABLE_PHARMACY_MCP" == "true" ]] && {
        echo "  pharmacy:"
        echo "    url: \"http://mcp-servers:8006/sse\""
    }
    [[ "$ENABLE_PIPEDRIVE_MCP" == "true" ]] && {
        echo "  pipedrive:"
        echo "    url: \"http://mcp-servers:8011/sse\""
    }
    [[ "$ENABLE_ERPLAIN_MCP" == "true" ]] && {
        echo "  erplain:"
        echo "    url: \"http://mcp-servers:8012/sse\""
    }
    [[ "$ENABLE_PENNYLANE_MCP" == "true" ]] && {
        echo "  pennylane:"
        echo "    url: \"http://mcp-servers:8013/sse\""
    }
    [[ "$ENABLE_DOCS_MCP" == "true" ]] && {
        echo "  docs:"
        echo "    url: \"http://mcp-servers:8014/sse\""
    }
    [[ "$ENABLE_SHEETS_MCP" == "true" ]] && {
        echo "  sheets:"
        echo "    url: \"http://mcp-servers:8015/sse\""
    }
    [[ "$ENABLE_CALENDAR_MCP" == "true" ]] && {
        echo "  calendar:"
        echo "    url: \"http://mcp-servers:8016/sse\""
    }
    [[ "$ENABLE_MICROSOFT365_MCP" == "true" ]] && {
        echo "  microsoft365:"
        echo "    url: \"http://mcp-servers:8020/sse\""
    }

    echo "  knowledge:"
    echo "    url: \"http://knowledge:8443/mcp\""
} > config/edge.yaml
ok "config/edge.yaml written"

# ---------- Write config/docker-config.json (Watchtower GHCR auth) -----------
info "Writing config/docker-config.json..."
GHCR_AUTH=$(echo -n "wardian-client:${GHCR_TOKEN}" | base64 -w0 2>/dev/null || echo -n "wardian-client:${GHCR_TOKEN}" | base64)
cat > config/docker-config.json <<DOCKEREOF
{
    "auths": {
        "ghcr.io": {
            "auth": "$GHCR_AUTH"
        }
    }
}
DOCKEREOF
ok "config/docker-config.json written"

# ---------- Pull images ------------------------------------------------------
if [[ "$OFFLINE" != "true" ]]; then
    info "Pulling Docker images (this may take a few minutes on first install)..."
    docker compose --profile onprem pull
    ok "Images pulled"
else
    info "Offline mode — using pre-loaded images (docker load)"
    # Verify at least one critical image exists locally
    if ! docker image inspect ghcr.io/romain13190/wardian-mcp-servers:latest &>/dev/null; then
        err "Images not found. Run 'docker load < wardian-edge-images.tar.gz' first."
    fi
    ok "Images present locally"
fi

# ---------- Start stack ------------------------------------------------------
info "Starting Wardian Edge..."
docker compose --profile onprem up -d
echo ""

# ---------- Wait for health ---------------------------------------------------
info "Waiting for services to be healthy..."

wait_healthy() {
    local service=$1
    local max_wait=${2:-120}
    local waited=0
    while [ $waited -lt $max_wait ]; do
        local status
        status=$(docker compose ps "$service" --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | head -1 || true)
        if echo "$status" | grep -q '"Health":"healthy"'; then
            ok "$service is healthy"
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
        printf "."
    done
    echo ""
    warn "$service did not become healthy within ${max_wait}s"
    warn "Check logs: docker compose logs $service"
    return 1
}

wait_healthy postgres 60
wait_healthy minio 30
wait_healthy mcp-servers 60
wait_healthy knowledge 60

# ---------- Status -----------------------------------------------------------
echo ""
docker compose --profile onprem ps
echo ""

echo -e "${BOLD}=============================================${NC}"
echo -e "   ${GREEN}Wardian Edge is running!${NC}"
echo -e "${BOLD}=============================================${NC}"
echo ""
echo "  Cloud URL:     $CLOUD_URL"
echo "  Org token:     ${ORG_TOKEN:0:16}..."
echo "  LLM provider:  $LLM_BASE_URL"
echo "  Gateway:       ON (WebSocket relay)"
echo ""
echo "  MCP Servers (always on):"
echo "    - database   (mcp-servers:8001)"
echo "    - memory     (mcp-servers:8002)"
echo "    - knowledge  (knowledge:8443)"
[[ -n "$ENABLED_MCPS" ]] && echo "    - optional:  ${ENABLED_MCPS}"
echo ""
echo "  Auto-update:   ON (Watchtower checks every 6h)"
echo ""
echo "  Commands:"
echo "    cd $(pwd)"
echo "    docker compose --profile onprem logs -f        # follow logs"
echo "    docker compose --profile onprem ps             # service status"
echo "    docker compose --profile onprem down            # stop"
echo "    docker compose --profile onprem down -v         # stop + DELETE data"
echo ""
