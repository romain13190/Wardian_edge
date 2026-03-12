#!/usr/bin/env bash
###############################################################################
# Wardian Edge — Interactive Setup
#
# Self-contained on-premise stack deployed at client sites.
# Services: PostgreSQL, MinIO, MCP Servers, Knowledge, Gateway
#
# This script:
#   1. Checks prerequisites (docker, docker compose, curl, openssl)
#   2. Collects org token, cloud URL, LLM credentials
#   3. Asks which optional MCP servers to enable
#   4. Generates secure passwords and encryption keys
#   5. Writes .env and config/edge.yaml (real values, not templates)
#   6. Starts Docker Compose and waits for health
#   7. Displays service status
###############################################################################

set -euo pipefail
cd "$(dirname "$0")"

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
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------- Pre-flight checks -----------------------------------------------
info "Checking prerequisites..."

for cmd in docker curl openssl; do
    if ! command -v "$cmd" &>/dev/null; then
        err "$cmd is not installed."
        exit 1
    fi
done

if ! docker compose version &>/dev/null; then
    err "Docker Compose v2 not found. Update Docker or install the compose plugin."
    exit 1
fi

ok "All prerequisites met"

echo ""
echo "============================================="
echo "   WARDIAN EDGE — Setup"
echo "============================================="
echo ""

# =============================================================================
# 1. Deployment Mode
# =============================================================================

echo -e "${BOLD}--- Deployment Mode ---${NC}"
echo ""
echo "  1. ${BOLD}cloud${NC}  — MCPs register directly with Wardian Cloud (same server / same network)"
echo "  2. ${BOLD}onprem${NC} — MCPs connect via Gateway WebSocket relay (behind firewall)"
echo ""
read -rp "$(echo -e "${CYAN}Mode [1=cloud / 2=onprem]:${NC} ")" MODE_CHOICE
case "${MODE_CHOICE:-2}" in
    1|cloud)  EDGE_MODE=cloud ;;
    2|onprem) EDGE_MODE=onprem ;;
    *)        EDGE_MODE=onprem ;;
esac
ok "Deployment mode: $EDGE_MODE"

# =============================================================================
# 2. Cloud / Gateway Connection
# =============================================================================

ORG_TOKEN=""
CLOUD_URL=""
WARDIAN_CLOUD_URL=""
MCP_REGISTRY_TOKEN=""

if [ "$EDGE_MODE" = "onprem" ]; then
    echo ""
    echo -e "${BOLD}--- Gateway Connection ---${NC}"
    echo ""
    echo "  Get your org token from the Wardian admin dashboard:"
    echo "  Settings > Organization > Gateway Token"
    echo ""
    read -rp "$(echo -e "${CYAN}ORG_TOKEN:${NC} ")" ORG_TOKEN
    if [ -z "$ORG_TOKEN" ]; then
        err "ORG_TOKEN is required for onprem mode."
        exit 1
    fi
    ok "Org token set"

    echo ""
    read -rp "$(echo -e "${CYAN}CLOUD_URL [wss://app.wardian.ai/ws/gateway]:${NC} ")" CLOUD_URL
    CLOUD_URL=${CLOUD_URL:-wss://app.wardian.ai/ws/gateway}
    ok "Cloud URL: $CLOUD_URL"
else
    echo ""
    echo -e "${BOLD}--- Cloud Connection ---${NC}"
    echo ""
    read -rp "$(echo -e "${CYAN}WARDIAN_CLOUD_URL [http://localhost:8000]:${NC} ")" WARDIAN_CLOUD_URL
    WARDIAN_CLOUD_URL=${WARDIAN_CLOUD_URL:-http://localhost:8000}
    ok "Cloud URL: $WARDIAN_CLOUD_URL"

    read -rp "$(echo -e "${CYAN}MCP_REGISTRY_TOKEN (optional, Enter to skip):${NC} ")" MCP_REGISTRY_TOKEN
    if [ -n "$MCP_REGISTRY_TOKEN" ]; then
        ok "Registry token set"
    else
        info "No registry token — dev mode (all requests accepted)"
    fi
fi

# =============================================================================
# 3. LLM Provider
# =============================================================================

echo ""
echo -e "${BOLD}--- LLM Provider ---${NC}"
echo ""
read -rp "$(echo -e "${CYAN}CHUTES_API_KEY:${NC} ")" CHUTES_API_KEY
if [ -z "$CHUTES_API_KEY" ]; then
    err "CHUTES_API_KEY is required."
    exit 1
fi

read -rp "$(echo -e "${CYAN}CHUTES_BASE_URL [https://llm.chutes.ai/v1]:${NC} ")" CHUTES_BASE_URL
CHUTES_BASE_URL=${CHUTES_BASE_URL:-https://llm.chutes.ai/v1}
ok "LLM provider configured"

# =============================================================================
# 4. MCP Servers
# =============================================================================

echo ""
echo -e "${BOLD}--- MCP Servers ---${NC}"
echo ""
info "Always active:"
echo "    database  (mcp-servers:8001)"
echo "    memory    (mcp-servers:8002)"
echo "    knowledge (knowledge:8443)"
echo ""

info "Optional MCP servers:"
echo ""
echo -e "  ${BOLD}Google Workspace${NC} (un seul compte Google pour tous) :"
echo "    1. Gmail      — Emails"
echo "    2. Drive      — Fichiers"
echo "    3. Calendar   — Agenda"
echo "    4. Sheets     — Tableurs"
echo "    5. Docs       — Documents"
echo ""
echo -e "  ${BOLD}Autres${NC} :"
echo "    6. GitHub     — Repositories"
echo "    7. Pharmacy   — Base WinPharma"
echo "    8. Pipedrive  — CRM commercial"
echo "    9. Erplain    — Gestion de stock"
echo "   10. Pennylane  — Comptabilite"
echo ""
read -rp "$(echo -e "${CYAN}Which ones to enable? (comma-separated numbers, 'all', or Enter to skip):${NC} ")" MCP_SELECTION

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

if [ -n "$MCP_SELECTION" ]; then
    if [ "$MCP_SELECTION" = "all" ]; then
        ENABLE_GMAIL_MCP=true
        ENABLE_DRIVE_MCP=true
        ENABLE_CALENDAR_MCP=true
        ENABLE_SHEETS_MCP=true
        ENABLE_DOCS_MCP=true
        ENABLE_GITHUB_MCP=true
        ENABLE_PHARMACY_MCP=true
        ENABLE_PIPEDRIVE_MCP=true
        ENABLE_ERPLAIN_MCP=true
        ENABLE_PENNYLANE_MCP=true
    else
        IFS=',' read -ra SELECTED <<< "$MCP_SELECTION"
        for num in "${SELECTED[@]}"; do
            num=$(echo "$num" | tr -d ' ')
            case "$num" in
                1)  ENABLE_GMAIL_MCP=true ;;
                2)  ENABLE_DRIVE_MCP=true ;;
                3)  ENABLE_CALENDAR_MCP=true ;;
                4)  ENABLE_SHEETS_MCP=true ;;
                5)  ENABLE_DOCS_MCP=true ;;
                6)  ENABLE_GITHUB_MCP=true ;;
                7)  ENABLE_PHARMACY_MCP=true ;;
                8)  ENABLE_PIPEDRIVE_MCP=true ;;
                9)  ENABLE_ERPLAIN_MCP=true ;;
                10) ENABLE_PENNYLANE_MCP=true ;;
                *)  warn "Unknown selection: $num (ignored)" ;;
            esac
        done
    fi
fi

# --- Detect if any Google MCP is enabled ---
NEEDS_GOOGLE=false
if [ "$ENABLE_GMAIL_MCP" = "true" ] || [ "$ENABLE_DRIVE_MCP" = "true" ] || \
   [ "$ENABLE_CALENDAR_MCP" = "true" ] || [ "$ENABLE_SHEETS_MCP" = "true" ] || \
   [ "$ENABLE_DOCS_MCP" = "true" ]; then
    NEEDS_GOOGLE=true
fi

# --- Collect credentials per provider (Google once, others individually) ---

PIPEDRIVE_API_TOKEN=""
PIPEDRIVE_COMPANY_DOMAIN=""
ERPLAIN_API_TOKEN=""
PENNYLANE_API_TOKEN=""
GMAIL_AUTH_MODE=""
GOOGLE_CLIENT_ID=""
GOOGLE_CLIENT_SECRET=""
GOOGLE_SERVICE_ACCOUNT_KEY=""
GOOGLE_WORKSPACE_USER=""

# --- Google (shared credentials for ALL Google MCPs) ---
if [ "$NEEDS_GOOGLE" = "true" ]; then
    GOOGLE_ENABLED=""
    [ "$ENABLE_GMAIL_MCP" = "true" ]    && GOOGLE_ENABLED="${GOOGLE_ENABLED} Gmail"
    [ "$ENABLE_DRIVE_MCP" = "true" ]    && GOOGLE_ENABLED="${GOOGLE_ENABLED} Drive"
    [ "$ENABLE_CALENDAR_MCP" = "true" ] && GOOGLE_ENABLED="${GOOGLE_ENABLED} Calendar"
    [ "$ENABLE_SHEETS_MCP" = "true" ]   && GOOGLE_ENABLED="${GOOGLE_ENABLED} Sheets"
    [ "$ENABLE_DOCS_MCP" = "true" ]     && GOOGLE_ENABLED="${GOOGLE_ENABLED} Docs"

    echo ""
    echo -e "${BOLD}--- Google Workspace Configuration ---${NC}"
    echo -e "  Services actives :${BOLD}${GOOGLE_ENABLED}${NC}"
    echo ""
    echo "  Un seul compte Google pour tous ces services."
    echo ""
    echo "  1. ${BOLD}service_account${NC} — Compte de service Google Workspace (recommande entreprise)"
    echo "     L'admin configure la delegation domain-wide une seule fois."
    echo "     Toutes les APIs (Gmail, Drive, Calendar, Sheets, Docs) passent par le meme compte."
    echo ""
    echo "  2. ${BOLD}oauth${NC} — Chaque utilisateur connecte son compte individuellement"
    echo "     Necessite un Client ID / Client Secret (Google Cloud Console)."
    echo ""
    read -rp "$(echo -e "${CYAN}Mode d'auth Google [1=service_account / 2=oauth]:${NC} ")" GOOGLE_AUTH_CHOICE
    case "${GOOGLE_AUTH_CHOICE:-1}" in
        1|service_account) GMAIL_AUTH_MODE=service_account ;;
        2|oauth)           GMAIL_AUTH_MODE=oauth ;;
        *)                 GMAIL_AUTH_MODE=service_account ;;
    esac
    ok "Google auth mode: $GMAIL_AUTH_MODE"

    if [ "$GMAIL_AUTH_MODE" = "service_account" ]; then
        echo ""
        echo "  Comment configurer (une seule fois pour tous les services Google) :"
        echo "    1. console.cloud.google.com > Creer un projet"
        echo "    2. Activer les APIs : Gmail, Drive, Calendar, Sheets, Docs"
        echo "    3. Creer un Service Account > Generer une cle JSON"
        echo "    4. admin.google.com > Securite > Controle API > Delegation domaine"
        echo "    5. Ajouter le client_id avec les scopes necessaires"
        echo ""
        read -rp "$(echo -e "${CYAN}Chemin vers le fichier JSON du service account:${NC} ")" SA_KEY_PATH
        if [ -z "$SA_KEY_PATH" ]; then
            err "Le chemin du fichier service account est requis."
            exit 1
        fi
        if [ ! -f "$SA_KEY_PATH" ]; then
            err "Fichier introuvable: $SA_KEY_PATH"
            exit 1
        fi
        ok "Service account: $SA_KEY_PATH"

        echo ""
        read -rp "$(echo -e "${CYAN}Email admin Google Workspace (ex: admin@entreprise.com):${NC} ")" GOOGLE_WORKSPACE_USER
        if [ -z "$GOOGLE_WORKSPACE_USER" ]; then
            err "L'email admin est requis pour la delegation domain-wide."
            exit 1
        fi
        ok "Google Workspace user: $GOOGLE_WORKSPACE_USER"

        # Copy service account file to config/
        cp "$SA_KEY_PATH" config/google-service-account.json
        GOOGLE_SERVICE_ACCOUNT_KEY="/app/config/google-service-account.json"
        ok "Service account copie dans config/"
    else
        echo ""
        echo "  Comment obtenir les credentials OAuth (une seule fois pour tous) :"
        echo "    1. console.cloud.google.com > APIs & Services > Credentials"
        echo "    2. Configurer l'ecran de consentement OAuth"
        echo "    3. Creer un ID client OAuth (type: Application Web)"
        echo "    4. Copier le Client ID et Client Secret"
        echo ""
        read -rp "$(echo -e "${CYAN}GOOGLE_CLIENT_ID:${NC} ")" GOOGLE_CLIENT_ID
        if [ -z "$GOOGLE_CLIENT_ID" ]; then
            err "GOOGLE_CLIENT_ID est requis en mode OAuth."
            exit 1
        fi
        read -rp "$(echo -e "${CYAN}GOOGLE_CLIENT_SECRET:${NC} ")" GOOGLE_CLIENT_SECRET
        if [ -z "$GOOGLE_CLIENT_SECRET" ]; then
            err "GOOGLE_CLIENT_SECRET est requis en mode OAuth."
            exit 1
        fi
        ok "Google OAuth configured (shared for${GOOGLE_ENABLED})"
        info "Chaque utilisateur devra connecter son compte Google dans l'interface Wardian."
    fi
fi

if [ "$ENABLE_PIPEDRIVE_MCP" = "true" ]; then
    echo ""
    echo -e "${BOLD}--- Pipedrive Configuration ---${NC}"
    echo "  Get your API token from: Pipedrive > Settings > Personal preferences > API"
    echo ""
    read -rp "$(echo -e "${CYAN}PIPEDRIVE_API_TOKEN:${NC} ")" PIPEDRIVE_API_TOKEN
    if [ -z "$PIPEDRIVE_API_TOKEN" ]; then
        err "PIPEDRIVE_API_TOKEN is required when Pipedrive MCP is enabled."
        exit 1
    fi
    read -rp "$(echo -e "${CYAN}PIPEDRIVE_COMPANY_DOMAIN (ex: acme for acme.pipedrive.com):${NC} ")" PIPEDRIVE_COMPANY_DOMAIN
    if [ -z "$PIPEDRIVE_COMPANY_DOMAIN" ]; then
        err "PIPEDRIVE_COMPANY_DOMAIN is required."
        exit 1
    fi
    ok "Pipedrive configured (domain: $PIPEDRIVE_COMPANY_DOMAIN)"
fi

if [ "$ENABLE_ERPLAIN_MCP" = "true" ]; then
    echo ""
    echo -e "${BOLD}--- Erplain Configuration ---${NC}"
    echo "  Get your API token from: Erplain > Profile icon > Edit my profile > Generate new token"
    echo ""
    read -rp "$(echo -e "${CYAN}ERPLAIN_API_TOKEN:${NC} ")" ERPLAIN_API_TOKEN
    if [ -z "$ERPLAIN_API_TOKEN" ]; then
        err "ERPLAIN_API_TOKEN is required when Erplain MCP is enabled."
        exit 1
    fi
    ok "Erplain configured"
fi

if [ "$ENABLE_PENNYLANE_MCP" = "true" ]; then
    echo ""
    echo -e "${BOLD}--- Pennylane Configuration ---${NC}"
    echo "  Get your API token from: Pennylane > Settings > API"
    echo ""
    read -rp "$(echo -e "${CYAN}PENNYLANE_API_TOKEN:${NC} ")" PENNYLANE_API_TOKEN
    if [ -z "$PENNYLANE_API_TOKEN" ]; then
        err "PENNYLANE_API_TOKEN is required when Pennylane MCP is enabled."
        exit 1
    fi
    ok "Pennylane configured"
fi

ENABLED_LIST=""
[ "$ENABLE_GMAIL_MCP" = "true" ]    && ENABLED_LIST="${ENABLED_LIST} gmail"
[ "$ENABLE_DRIVE_MCP" = "true" ]    && ENABLED_LIST="${ENABLED_LIST} drive"
[ "$ENABLE_CALENDAR_MCP" = "true" ] && ENABLED_LIST="${ENABLED_LIST} calendar"
[ "$ENABLE_SHEETS_MCP" = "true" ]   && ENABLED_LIST="${ENABLED_LIST} sheets"
[ "$ENABLE_DOCS_MCP" = "true" ]     && ENABLED_LIST="${ENABLED_LIST} docs"
[ "$ENABLE_GITHUB_MCP" = "true" ]   && ENABLED_LIST="${ENABLED_LIST} github"
[ "$ENABLE_PHARMACY_MCP" = "true" ] && ENABLED_LIST="${ENABLED_LIST} pharmacy"
[ "$ENABLE_PIPEDRIVE_MCP" = "true" ] && ENABLED_LIST="${ENABLED_LIST} pipedrive"
[ "$ENABLE_ERPLAIN_MCP" = "true" ]  && ENABLED_LIST="${ENABLED_LIST} erplain"
[ "$ENABLE_PENNYLANE_MCP" = "true" ] && ENABLED_LIST="${ENABLED_LIST} pennylane"

if [ -n "$ENABLED_LIST" ]; then
    ok "Optional MCP servers:${ENABLED_LIST}"
else
    info "No optional MCP servers selected"
fi

# =============================================================================
# 5. Auto-Update (Watchtower)
# =============================================================================

echo ""
echo -e "${BOLD}--- Auto-Update ---${NC}"
echo ""
info "Watchtower will automatically update Wardian Edge when new versions are available."
echo "  A read-only GitHub token is needed to pull images from ghcr.io."
echo "  Generate one at: https://github.com/settings/tokens"
echo "  Required scope: read:packages"
echo ""
read -rp "$(echo -e "${CYAN}GHCR_TOKEN:${NC} ")" GHCR_TOKEN
if [ -z "$GHCR_TOKEN" ]; then
    warn "No GHCR token provided. Auto-update will be disabled."
    warn "You can add it later in .env and regenerate config/docker-config.json"
    WATCHTOWER_ENABLED=false
else
    ok "GHCR token set — auto-update enabled (checks every 6h)"
    WATCHTOWER_ENABLED=true
fi

# =============================================================================
# 6. Generate secure passwords and keys
# =============================================================================

echo ""
info "Generating secure credentials..."

POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
MINIO_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
INTEGRATION_ENCRYPTION_KEY=$(openssl rand -hex 32)

ok "POSTGRES_PASSWORD generated"
ok "MINIO_ROOT_PASSWORD generated"
ok "INTEGRATION_ENCRYPTION_KEY generated"

# =============================================================================
# 7. Write .env
# =============================================================================

echo ""
info "Writing .env..."

cat > .env <<ENVEOF
# Generated by wardian-edge/setup.sh on $(date -Iseconds)
# Re-run setup.sh to reconfigure.

# --- Deployment mode ---
EDGE_MODE=$EDGE_MODE

# --- Gateway (onprem mode) ---
ORG_TOKEN=$ORG_TOKEN
CLOUD_URL=$CLOUD_URL

# --- Self-registration (cloud mode) ---
WARDIAN_CLOUD_URL=$WARDIAN_CLOUD_URL
MCP_REGISTRY_TOKEN=$MCP_REGISTRY_TOKEN

# --- LLM ---
CHUTES_API_KEY=$CHUTES_API_KEY
CHUTES_BASE_URL=$CHUTES_BASE_URL

# --- PostgreSQL ---
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# --- MinIO / S3 ---
MINIO_ROOT_USER=wardian
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD

# --- MCP Servers ---
ENABLE_GMAIL_MCP=$ENABLE_GMAIL_MCP
ENABLE_DRIVE_MCP=$ENABLE_DRIVE_MCP
ENABLE_GITHUB_MCP=$ENABLE_GITHUB_MCP
ENABLE_PHARMACY_MCP=$ENABLE_PHARMACY_MCP
ENABLE_CALENDAR_MCP=$ENABLE_CALENDAR_MCP
ENABLE_SHEETS_MCP=$ENABLE_SHEETS_MCP
ENABLE_DOCS_MCP=$ENABLE_DOCS_MCP
ENABLE_PIPEDRIVE_MCP=$ENABLE_PIPEDRIVE_MCP
ENABLE_ERPLAIN_MCP=$ENABLE_ERPLAIN_MCP
ENABLE_PENNYLANE_MCP=$ENABLE_PENNYLANE_MCP

# --- Google Workspace (shared for all Google MCPs) ---
GMAIL_AUTH_MODE=$GMAIL_AUTH_MODE
GOOGLE_CLIENT_ID=$GOOGLE_CLIENT_ID
GOOGLE_CLIENT_SECRET=$GOOGLE_CLIENT_SECRET
GOOGLE_SERVICE_ACCOUNT_KEY=$GOOGLE_SERVICE_ACCOUNT_KEY
GOOGLE_WORKSPACE_USER=$GOOGLE_WORKSPACE_USER
DRIVE_TARGET_USER=$GOOGLE_WORKSPACE_USER

# --- Pipedrive ---
PIPEDRIVE_API_TOKEN=$PIPEDRIVE_API_TOKEN
PIPEDRIVE_COMPANY_DOMAIN=$PIPEDRIVE_COMPANY_DOMAIN

# --- Erplain ---
ERPLAIN_API_TOKEN=$ERPLAIN_API_TOKEN

# --- Pennylane ---
PENNYLANE_API_TOKEN=$PENNYLANE_API_TOKEN

# --- Integration encryption ---
INTEGRATION_ENCRYPTION_KEY=$INTEGRATION_ENCRYPTION_KEY

# --- Auto-update (Watchtower) ---
GHCR_TOKEN=${GHCR_TOKEN:-}
WATCHTOWER_POLL_INTERVAL=21600
ENVEOF

ok ".env written"

# =============================================================================
# 8. Generate config/edge.yaml
# =============================================================================

mkdir -p config

# Ensure google-service-account.json exists (even if empty) so volume mount doesn't fail
if [ ! -f config/google-service-account.json ]; then
    echo '{}' > config/google-service-account.json
fi

if [ "$EDGE_MODE" = "onprem" ]; then
    info "Generating config/edge.yaml (gateway config)..."

    {
        echo "# Generated by wardian-edge/setup.sh on $(date -Iseconds)"
        echo "# Re-run setup.sh to regenerate."
        echo ""
        echo "org_token: \"$ORG_TOKEN\""
        echo "cloud_url: \"$CLOUD_URL\""
        echo ""
        echo "servers:"
        echo "  database:"
        echo "    url: \"http://mcp-servers:8001/sse\""
        echo "  memory:"
        echo "    url: \"http://mcp-servers:8002/sse\""

        if [ "$ENABLE_GMAIL_MCP" = "true" ]; then
            echo "  gmail:"
            echo "    url: \"http://mcp-servers:8003/sse\""
        fi

        if [ "$ENABLE_DRIVE_MCP" = "true" ]; then
            echo "  drive:"
            echo "    url: \"http://mcp-servers:8004/sse\""
        fi

        if [ "$ENABLE_GITHUB_MCP" = "true" ]; then
            echo "  github:"
            echo "    url: \"http://mcp-servers:8005/sse\""
        fi

        if [ "$ENABLE_PHARMACY_MCP" = "true" ]; then
            echo "  pharmacy:"
            echo "    url: \"http://mcp-servers:8006/sse\""
        fi

        if [ "$ENABLE_CALENDAR_MCP" = "true" ]; then
            echo "  calendar:"
            echo "    url: \"http://mcp-servers:8016/sse\""
        fi

        if [ "$ENABLE_SHEETS_MCP" = "true" ]; then
            echo "  sheets:"
            echo "    url: \"http://mcp-servers:8015/sse\""
        fi

        if [ "$ENABLE_DOCS_MCP" = "true" ]; then
            echo "  docs:"
            echo "    url: \"http://mcp-servers:8014/sse\""
        fi

        if [ "$ENABLE_PIPEDRIVE_MCP" = "true" ]; then
            echo "  pipedrive:"
            echo "    url: \"http://mcp-servers:8011/sse\""
        fi

        if [ "$ENABLE_ERPLAIN_MCP" = "true" ]; then
            echo "  erplain:"
            echo "    url: \"http://mcp-servers:8012/sse\""
        fi

        if [ "$ENABLE_PENNYLANE_MCP" = "true" ]; then
            echo "  pennylane:"
            echo "    url: \"http://mcp-servers:8013/sse\""
        fi

        echo "  knowledge:"
        echo "    url: \"http://knowledge:8443/mcp\""
    } > config/edge.yaml

    ok "config/edge.yaml written"
else
    info "Cloud mode — no gateway config needed"
    echo "# Cloud mode — gateway not used" > config/edge.yaml
fi

# =============================================================================
# 9. Generate config/docker-config.json (Watchtower GHCR auth)
# =============================================================================

if [ "$WATCHTOWER_ENABLED" = "true" ]; then
    info "Generating config/docker-config.json for GHCR auth..."
    GHCR_AUTH=$(echo -n "wardian-client:${GHCR_TOKEN}" | base64)
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
else
    # Empty config so the volume mount doesn't fail
    echo '{}' > config/docker-config.json
    info "config/docker-config.json written (empty — no GHCR token)"
fi

# =============================================================================
# 10. Build & start
# =============================================================================

echo ""
info "Building and starting Wardian Edge..."

if [ "$EDGE_MODE" = "onprem" ]; then
    docker compose --profile onprem up -d --pull always
else
    docker compose up -d --pull always
fi

# =============================================================================
# 11. Wait for PostgreSQL healthcheck
# =============================================================================

echo ""
info "Waiting for PostgreSQL to be ready..."

MAX_WAIT=120
WAITED=0

while [ $WAITED -lt $MAX_WAIT ]; do
    STATUS=$(docker compose ps postgres --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | head -1 || true)
    if echo "$STATUS" | grep -q '"Health":"healthy"'; then
        ok "PostgreSQL is healthy"
        break
    fi
    sleep 2
    WAITED=$((WAITED + 2))
    printf "."
done
echo ""

if [ $WAITED -ge $MAX_WAIT ]; then
    err "PostgreSQL did not become healthy within ${MAX_WAIT}s."
    err "Check logs: docker compose logs postgres"
    exit 1
fi

# =============================================================================
# 12. Display service status
# =============================================================================

echo ""
info "Service status:"
echo ""
docker compose ps
echo ""

# Build summary
echo "============================================="
echo -e "   ${GREEN}Wardian Edge is running!${NC}"
echo "============================================="
echo ""
echo "  Mode:         $EDGE_MODE"
if [ "$EDGE_MODE" = "onprem" ]; then
    echo "  Cloud URL:    $CLOUD_URL"
    echo "  Org Token:    ${ORG_TOKEN:0:12}..."
    echo "  Gateway:      ON (WebSocket relay)"
else
    echo "  Cloud URL:    $WARDIAN_CLOUD_URL"
    echo "  Gateway:      OFF (MCPs self-register via HTTP)"
fi
echo ""
echo "  MCP Servers (always on):"
echo "    - database   (mcp-servers:8001)"
echo "    - memory     (mcp-servers:8002)"
echo "    - knowledge  (knowledge:8443)"

if [ "$ENABLE_GMAIL_MCP" = "true" ]; then
    echo "    - gmail      (mcp-servers:8003)"
fi
if [ "$ENABLE_DRIVE_MCP" = "true" ]; then
    echo "    - drive      (mcp-servers:8004)"
fi
if [ "$ENABLE_GITHUB_MCP" = "true" ]; then
    echo "    - github     (mcp-servers:8005)"
fi
if [ "$ENABLE_PHARMACY_MCP" = "true" ]; then
    echo "    - pharmacy   (mcp-servers:8006)"
fi
if [ "$ENABLE_CALENDAR_MCP" = "true" ]; then
    echo "    - calendar   (mcp-servers:8016)"
fi
if [ "$ENABLE_SHEETS_MCP" = "true" ]; then
    echo "    - sheets     (mcp-servers:8015)"
fi
if [ "$ENABLE_DOCS_MCP" = "true" ]; then
    echo "    - docs       (mcp-servers:8014)"
fi
if [ "$ENABLE_PIPEDRIVE_MCP" = "true" ]; then
    echo "    - pipedrive  (mcp-servers:8011)"
fi
if [ "$ENABLE_ERPLAIN_MCP" = "true" ]; then
    echo "    - erplain    (mcp-servers:8012)"
fi
if [ "$ENABLE_PENNYLANE_MCP" = "true" ]; then
    echo "    - pennylane  (mcp-servers:8013)"
fi

if [ "$WATCHTOWER_ENABLED" = "true" ]; then
    echo ""
    echo -e "  ${GREEN}Auto-update: ON${NC} (checks every 6h)"
    echo "    Watchtower will pull new images from ghcr.io automatically."
else
    echo ""
    echo -e "  ${YELLOW}Auto-update: OFF${NC} (no GHCR token)"
    echo "    To enable: add GHCR_TOKEN to .env and re-run setup.sh"
fi

echo ""
echo "  Commands:"
echo "    docker compose logs -f           # follow logs"
echo "    docker compose logs watchtower   # auto-update logs"
echo "    docker compose ps                # service status"
echo "    docker compose down              # stop"
echo "    docker compose down -v           # stop and DELETE data"
echo "    docker compose up -d --pull always     # rebuild & restart"
echo "    ./setup.sh                       # reconfigure"
echo ""
