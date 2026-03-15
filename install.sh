#!/usr/bin/env bash
###############################################################################
# Wardian Edge — One-Command Installer
#
# Deploys the full Wardian Edge stack (PostgreSQL, MinIO, MCP Servers,
# Knowledge Engine, Gateway) using pre-built Docker images from ghcr.io.
#
# Usage:
#   bash install.sh --token <ORG_TOKEN> --ghcr <GHCR_TOKEN> --llm-key <CHUTES_API_KEY>
#
# Options:
#   --token       Gateway org token (from Wardian admin dashboard)
#   --ghcr        GitHub token with read:packages scope (to pull private images)
#   --llm-key     Chutes API key for LLM access
#   --llm-url     Chutes base URL (default: https://llm.chutes.ai/v1)
#   --cloud-url   Cloud WebSocket URL (default: wss://app.wardian.ai/ws/gateway)
#   --mcps        Comma-separated optional MCPs: gmail,drive,github,pharmacy,pipedrive,erplain,pennylane
#   --google-sa-key      Path to Google service account JSON (for gmail/drive with service_account mode)
#   --google-client-id   Google OAuth client ID (for gmail/drive with oauth mode)
#   --google-client-secret Google OAuth client secret (for gmail/drive with oauth mode)
#   --drive-user         Google Workspace admin email for Drive impersonation (service_account mode)
#   --pipedrive-token    Pipedrive API token (required if pipedrive in --mcps)
#   --pipedrive-domain   Pipedrive company domain (required if pipedrive in --mcps)
#   --erplain-token      Erplain API token (required if erplain in --mcps)
#   --pennylane-token    Pennylane API token (required if pennylane in --mcps)
#   --dir         Install directory (default: ./wardian-edge)
#   -y            Skip confirmation prompt
#   --help        Show this help
#
# Example:
#   bash install.sh \
#     --token wdn_gw_abc123 \
#     --ghcr ghp_xxx \
#     --llm-key sk-xxx \
#     --mcps gmail,drive
###############################################################################

set -euo pipefail

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
CHUTES_API_KEY=""
CHUTES_BASE_URL="https://llm.chutes.ai/v1"
CLOUD_URL="wss://app.wardian.ai/ws/gateway"
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
AUTO_YES=false

show_help() {
    head -30 "$0" | grep '^#' | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --token)     ORG_TOKEN="$2"; shift 2 ;;
        --ghcr)      GHCR_TOKEN="$2"; shift 2 ;;
        --llm-key)   CHUTES_API_KEY="$2"; shift 2 ;;
        --llm-url)   CHUTES_BASE_URL="$2"; shift 2 ;;
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
        --dir)       INSTALL_DIR="$2"; shift 2 ;;
        -y)          AUTO_YES=true; shift ;;
        --help|-h)   show_help ;;
        *)           err "Unknown option: $1. Use --help for usage." ;;
    esac
done

# ---------- Validate required args ------------------------------------------
[[ -z "$ORG_TOKEN" ]]     && err "Missing --token (gateway org token)"
[[ -z "$GHCR_TOKEN" ]]    && err "Missing --ghcr (GitHub token for pulling images)"
[[ -z "$CHUTES_API_KEY" ]] && err "Missing --llm-key (Chutes API key)"

# ---------- Parse MCP selection ----------------------------------------------
ENABLE_GMAIL_MCP=false
ENABLE_DRIVE_MCP=false
ENABLE_GITHUB_MCP=false
ENABLE_PHARMACY_MCP=false
ENABLE_PIPEDRIVE_MCP=false
ENABLE_ERPLAIN_MCP=false
ENABLE_PENNYLANE_MCP=false

if [[ -n "$MCPS" ]]; then
    IFS=',' read -ra MCP_LIST <<< "$MCPS"
    for mcp in "${MCP_LIST[@]}"; do
        case "$(echo "$mcp" | tr -d ' ' | tr '[:upper:]' '[:lower:]')" in
            gmail)     ENABLE_GMAIL_MCP=true ;;
            drive)     ENABLE_DRIVE_MCP=true ;;
            github)    ENABLE_GITHUB_MCP=true ;;
            pharmacy)  ENABLE_PHARMACY_MCP=true ;;
            pipedrive) ENABLE_PIPEDRIVE_MCP=true ;;
            erplain)   ENABLE_ERPLAIN_MCP=true ;;
            pennylane) ENABLE_PENNYLANE_MCP=true ;;
            *)         warn "Unknown MCP: $mcp (ignored)" ;;
        esac
    done
fi

# Determine Google auth mode
if [[ "$ENABLE_GMAIL_MCP" == "true" || "$ENABLE_DRIVE_MCP" == "true" ]]; then
    if [[ -n "$GOOGLE_SERVICE_ACCOUNT_KEY_PATH" ]]; then
        GMAIL_AUTH_MODE=service_account
        [[ ! -f "$GOOGLE_SERVICE_ACCOUNT_KEY_PATH" ]] && err "Service account file not found: $GOOGLE_SERVICE_ACCOUNT_KEY_PATH"
    elif [[ -n "$GOOGLE_CLIENT_ID" && -n "$GOOGLE_CLIENT_SECRET" ]]; then
        GMAIL_AUTH_MODE=oauth
    else
        err "Gmail/Drive enabled but no Google credentials provided. Use --google-sa-key or --google-client-id + --google-client-secret"
    fi
fi
[[ "$ENABLE_DRIVE_MCP" == "true" && "$GMAIL_AUTH_MODE" == "service_account" && -z "$DRIVE_TARGET_USER" ]] && err "Drive enabled with service account but --drive-user not provided"

# Validate credentials for enabled MCPs
[[ "$ENABLE_PIPEDRIVE_MCP" == "true" && -z "$PIPEDRIVE_API_TOKEN" ]] && err "Pipedrive enabled but --pipedrive-token not provided"
[[ "$ENABLE_PIPEDRIVE_MCP" == "true" && -z "$PIPEDRIVE_COMPANY_DOMAIN" ]] && err "Pipedrive enabled but --pipedrive-domain not provided"
[[ "$ENABLE_ERPLAIN_MCP" == "true" && -z "$ERPLAIN_API_TOKEN" ]] && err "Erplain enabled but --erplain-token not provided"
[[ "$ENABLE_PENNYLANE_MCP" == "true" && -z "$PENNYLANE_API_TOKEN" ]] && err "Pennylane enabled but --pennylane-token not provided"

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
echo "  LLM provider:  $CHUTES_BASE_URL"
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
[[ "$ENABLE_GITHUB_MCP" == "true" ]]    && ENABLED_MCPS="${ENABLED_MCPS} github"
[[ "$ENABLE_PHARMACY_MCP" == "true" ]]  && ENABLED_MCPS="${ENABLED_MCPS} pharmacy"
[[ "$ENABLE_PIPEDRIVE_MCP" == "true" ]] && ENABLED_MCPS="${ENABLED_MCPS} pipedrive"
[[ "$ENABLE_ERPLAIN_MCP" == "true" ]]   && ENABLED_MCPS="${ENABLED_MCPS} erplain"
[[ "$ENABLE_PENNYLANE_MCP" == "true" ]] && ENABLED_MCPS="${ENABLED_MCPS} pennylane"

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
info "Logging in to ghcr.io..."
echo "$GHCR_TOKEN" | docker login ghcr.io -u wardian-client --password-stdin 2>/dev/null \
    || err "Failed to login to ghcr.io. Check your --ghcr token."
ok "Logged in to ghcr.io"

# ---------- Create install directory -----------------------------------------
mkdir -p "$INSTALL_DIR/config"
cd "$INSTALL_DIR"

# ---------- Generate credentials ---------------------------------------------
info "Generating secure credentials..."
POSTGRES_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
MINIO_ROOT_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
INTEGRATION_ENCRYPTION_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())")
ok "Credentials generated"

# ---------- Copy Google service account if provided ---------------------------
if [[ -n "$GOOGLE_SERVICE_ACCOUNT_KEY_PATH" ]]; then
    cp "$GOOGLE_SERVICE_ACCOUNT_KEY_PATH" config/google-service-account.json
    GOOGLE_SERVICE_ACCOUNT_KEY="/app/config/google-service-account.json"
    ok "Google service account copied to config/"
else
    # Empty file so docker volume mount doesn't fail
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

# LLM
CHUTES_API_KEY=$CHUTES_API_KEY
CHUTES_BASE_URL=$CHUTES_BASE_URL

# PostgreSQL
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

# MinIO
MINIO_ROOT_USER=wardian
MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD

# MCP Servers
ENABLE_GMAIL_MCP=$ENABLE_GMAIL_MCP
ENABLE_DRIVE_MCP=$ENABLE_DRIVE_MCP
ENABLE_GITHUB_MCP=$ENABLE_GITHUB_MCP
ENABLE_PHARMACY_MCP=$ENABLE_PHARMACY_MCP
ENABLE_PIPEDRIVE_MCP=$ENABLE_PIPEDRIVE_MCP
ENABLE_ERPLAIN_MCP=$ENABLE_ERPLAIN_MCP
ENABLE_PENNYLANE_MCP=$ENABLE_PENNYLANE_MCP

# Google (Gmail / Drive)
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

# Auto-update
GHCR_TOKEN=$GHCR_TOKEN
WATCHTOWER_POLL_INTERVAL=21600
ENVEOF
ok ".env written"

# ---------- Write docker-compose.yml ----------------------------------------
info "Writing docker-compose.yml..."
cat > docker-compose.yml <<'COMPOSEEOF'
services:

  watchtower:
    image: containrrr/watchtower:latest
    environment:
      WATCHTOWER_LABEL_ENABLE: "true"
      WATCHTOWER_POLL_INTERVAL: ${WATCHTOWER_POLL_INTERVAL:-21600}
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_ROLLING_RESTART: "true"
      WATCHTOWER_INCLUDE_RESTARTING: "true"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./config/docker-config.json:/config.json:ro
    restart: unless-stopped

  postgres:
    image: pgvector/pgvector:pg16
    environment:
      POSTGRES_DB: wardian_edge
      POSTGRES_USER: wardian
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
    volumes:
      - edge_pgdata:/var/lib/postgresql/data
      - ./init.sql:/docker-entrypoint-initdb.d/init.sql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U wardian -d wardian_edge"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped

  minio:
    image: minio/minio:latest
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER:-wardian}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD}
    command: minio server /data --console-address ":9001"
    volumes:
      - edge_s3data:/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 10s
      timeout: 5s
      retries: 3
    restart: unless-stopped

  minio-init:
    image: minio/mc:latest
    depends_on:
      minio:
        condition: service_healthy
    environment:
      MINIO_ROOT_USER: \${MINIO_ROOT_USER:-wardian}
      MINIO_ROOT_PASSWORD: \${MINIO_ROOT_PASSWORD}
    entrypoint: >
      sh -c "
        mc alias set edge http://minio:9000 \$\$MINIO_ROOT_USER \$\$MINIO_ROOT_PASSWORD &&
        mc mb --ignore-existing edge/wardian-vault &&
        echo 'Bucket wardian-vault ready'
      "
    restart: "no"

  mcp-servers:
    image: ghcr.io/romain13190/wardian-mcp-servers:latest
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
    environment:
      WARDIAN_DATABASE_URL: postgresql://wardian:${POSTGRES_PASSWORD}@postgres:5432/wardian_edge
      CHUTES_API_KEY: ${CHUTES_API_KEY}
      CHUTES_BASE_URL: ${CHUTES_BASE_URL:-https://llm.chutes.ai/v1}
      INTEGRATION_ENCRYPTION_KEY: ${INTEGRATION_ENCRYPTION_KEY:-}
      ENABLE_GMAIL_MCP: ${ENABLE_GMAIL_MCP:-false}
      ENABLE_DRIVE_MCP: ${ENABLE_DRIVE_MCP:-false}
      ENABLE_GITHUB_MCP: ${ENABLE_GITHUB_MCP:-false}
      ENABLE_PHARMACY_MCP: ${ENABLE_PHARMACY_MCP:-false}
      ENABLE_PIPEDRIVE_MCP: ${ENABLE_PIPEDRIVE_MCP:-false}
      ENABLE_ERPLAIN_MCP: ${ENABLE_ERPLAIN_MCP:-false}
      ENABLE_PENNYLANE_MCP: ${ENABLE_PENNYLANE_MCP:-false}
      GMAIL_AUTH_MODE: ${GMAIL_AUTH_MODE:-oauth}
      GOOGLE_CLIENT_ID: ${GOOGLE_CLIENT_ID:-}
      GOOGLE_CLIENT_SECRET: ${GOOGLE_CLIENT_SECRET:-}
      GOOGLE_SERVICE_ACCOUNT_KEY: ${GOOGLE_SERVICE_ACCOUNT_KEY:-}
      DRIVE_TARGET_USER: ${DRIVE_TARGET_USER:-}
      PIPEDRIVE_API_TOKEN: ${PIPEDRIVE_API_TOKEN:-}
      PIPEDRIVE_COMPANY_DOMAIN: ${PIPEDRIVE_COMPANY_DOMAIN:-}
      ERPLAIN_API_TOKEN: ${ERPLAIN_API_TOKEN:-}
      PENNYLANE_API_TOKEN: ${PENNYLANE_API_TOKEN:-}
    volumes:
      - ./config/google-service-account.json:/app/config/google-service-account.json:ro
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8001/sse >/dev/null 2>&1 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s
    restart: unless-stopped

  knowledge:
    image: ghcr.io/romain13190/wardian-knowledge:latest
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
    environment:
      DATABASE_URL: postgresql://wardian:${POSTGRES_PASSWORD}@postgres:5432/wardian_edge
      CHUTES_API_KEY: ${CHUTES_API_KEY}
      CHUTES_BASE_URL: ${CHUTES_BASE_URL:-https://llm.chutes.ai/v1}
      MCP_PORT: "8443"
      EMBEDDING_DIM: "${EMBEDDING_DIM:-4096}"
      MINIO_ENDPOINT: http://minio:9000
      MINIO_ACCESS_KEY: ${MINIO_ROOT_USER:-wardian}
      MINIO_SECRET_KEY: ${MINIO_ROOT_PASSWORD}
      MINIO_BUCKET: wardian-vault
      ALLOWED_MCP_URL_PREFIXES: "http://localhost:,http://mcp-servers:"
    depends_on:
      postgres:
        condition: service_healthy
      minio-init:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD-SHELL", "curl -sf http://localhost:8443/mcp >/dev/null 2>&1 || exit 1"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 15s
    restart: unless-stopped

  gateway:
    image: ghcr.io/romain13190/wardian-gateway:latest
    labels:
      - "com.centurylinklabs.watchtower.enable=true"
    profiles:
      - onprem
    volumes:
      - ./config/edge.yaml:/app/wardian-gateway.yaml:ro
    depends_on:
      mcp-servers:
        condition: service_healthy
      knowledge:
        condition: service_healthy
    restart: unless-stopped

volumes:
  edge_pgdata:
  edge_s3data:
COMPOSEEOF
ok "docker-compose.yml written"

# ---------- Write init.sql ---------------------------------------------------
info "Writing init.sql..."
cat > init.sql <<'SQLEOF'
CREATE EXTENSION IF NOT EXISTS vector;

CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    org_id TEXT,
    title TEXT,
    model_id TEXT,
    messages JSONB,
    created_at BIGINT NOT NULL,
    updated_at BIGINT,
    pinned BOOLEAN NOT NULL DEFAULT FALSE,
    conversation_summary TEXT,
    open_threads JSONB,
    key_facts JSONB,
    summary_updated_at BIGINT,
    summary_message_count INT,
    summary_token_est INT,
    encrypted_data TEXT,
    encrypted BOOLEAN DEFAULT false
);
CREATE INDEX IF NOT EXISTS idx_conv_user ON conversations(user_id);
CREATE INDEX IF NOT EXISTS idx_conv_org ON conversations(org_id);

CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    user_id TEXT,
    org_id TEXT,
    role TEXT NOT NULL,
    content TEXT,
    tokens INT,
    cost_cents INT,
    is_encrypted BOOLEAN DEFAULT FALSE,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_msg_conv ON messages(conversation_id);

CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    org_id TEXT,
    user_id TEXT NOT NULL,
    name TEXT NOT NULL,
    content_type TEXT,
    size_bytes INTEGER,
    text_content TEXT,
    visibility TEXT NOT NULL DEFAULT 'private',
    metadata JSONB,
    created_at BIGINT NOT NULL,
    updated_at BIGINT
);
CREATE INDEX IF NOT EXISTS idx_doc_org ON documents(org_id, user_id);

CREATE TABLE IF NOT EXISTS document_chunks (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    org_id TEXT,
    user_id TEXT NOT NULL,
    chunk_index INTEGER NOT NULL,
    content TEXT NOT NULL,
    token_count INTEGER,
    visibility TEXT NOT NULL DEFAULT 'private',
    created_at BIGINT NOT NULL,
    embedding vector(4096)
);
CREATE INDEX IF NOT EXISTS idx_chunks_org ON document_chunks(org_id, visibility);
CREATE INDEX IF NOT EXISTS idx_chunks_user ON document_chunks(org_id, user_id, visibility);
CREATE INDEX IF NOT EXISTS idx_chunks_doc ON document_chunks(document_id);

CREATE TABLE IF NOT EXISTS user_memory (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    org_id TEXT DEFAULT '',
    category TEXT DEFAULT 'general',
    content TEXT NOT NULL,
    embedding vector(4096),
    importance REAL DEFAULT 0.5,
    access_count INTEGER DEFAULT 0,
    last_accessed BIGINT,
    expires_at BIGINT,
    created_at BIGINT NOT NULL,
    updated_at BIGINT
);
CREATE INDEX IF NOT EXISTS idx_memory_user ON user_memory(user_id, org_id);

CREATE TABLE IF NOT EXISTS integration_credentials (
    id TEXT PRIMARY KEY,
    user_id TEXT NOT NULL,
    org_id TEXT DEFAULT '',
    provider TEXT NOT NULL,
    encrypted_access_token TEXT NOT NULL,
    encrypted_refresh_token TEXT,
    token_expiry BIGINT,
    scopes TEXT,
    email_address TEXT,
    created_at BIGINT NOT NULL,
    updated_at BIGINT,
    UNIQUE(user_id, provider)
);
CREATE INDEX IF NOT EXISTS idx_cred_user ON integration_credentials(user_id, provider);

CREATE TABLE IF NOT EXISTS audit_logs (
    id TEXT PRIMARY KEY,
    user_id TEXT,
    org_id TEXT,
    action TEXT NOT NULL,
    resource_type TEXT,
    resource_id TEXT,
    details JSONB,
    created_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_audit_org ON audit_logs(org_id, created_at);
SQLEOF
ok "init.sql written"

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
    }
    [[ "$ENABLE_DRIVE_MCP" == "true" ]] && {
        echo "  drive:"
        echo "    url: \"http://mcp-servers:8004/sse\""
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
info "Pulling Docker images (this may take a few minutes)..."
docker compose --profile onprem pull 2>&1 | grep -E "Pull|Downloaded|up to date" || true
ok "Images pulled"

# ---------- Start stack ------------------------------------------------------
info "Starting Wardian Edge..."
docker compose --profile onprem up -d
echo ""

# ---------- Wait for PostgreSQL ----------------------------------------------
info "Waiting for PostgreSQL..."
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
    err "PostgreSQL did not become healthy within ${MAX_WAIT}s. Check: docker compose logs postgres"
fi

# ---------- Wait for services ------------------------------------------------
info "Waiting for services to be ready..."
sleep 10

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
echo "  Gateway:       ON (WebSocket relay)"
echo ""
echo "  Services:"
echo "    - PostgreSQL (pgvector)"
echo "    - MinIO (object storage)"
echo "    - MCP Servers (database, memory)"
echo "    - Knowledge Engine (RAG)"
echo "    - Gateway (WebSocket relay)"
[[ -n "$ENABLED_MCPS" ]] && echo "    - Optional MCPs:${ENABLED_MCPS}"
echo ""
echo "  Auto-update:   ON (Watchtower checks every 6h)"
echo ""
echo "  Commands:"
echo "    cd $INSTALL_DIR"
echo "    docker compose --profile onprem logs -f        # follow logs"
echo "    docker compose --profile onprem ps             # service status"
echo "    docker compose --profile onprem down            # stop"
echo "    docker compose --profile onprem down -v         # stop + DELETE data"
echo "    docker compose --profile onprem up -d           # restart"
echo ""
