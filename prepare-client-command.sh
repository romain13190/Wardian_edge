#!/usr/bin/env bash
###############################################################################
# Prépare la commande d'installation à envoyer au client.
#
# Tu lances ce script AVANT le call. Il te pose les questions,
# et génère la commande exacte que le client n'a plus qu'à copier-coller.
###############################################################################

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}=============================================${NC}"
echo -e "${BOLD}   Préparer la commande client${NC}"
echo -e "${BOLD}=============================================${NC}"
echo ""

# --- Client OS ---
echo -e "${BOLD}OS du client :${NC}"
echo "  1. Linux / macOS"
echo "  2. Windows (Docker Desktop)"
echo ""
read -rp "$(echo -e "${CYAN}OS [1/2]:${NC} ")" OS_CHOICE
case "${OS_CHOICE:-1}" in
    2|windows|win) CLIENT_OS=windows ;;
    *)             CLIENT_OS=linux ;;
esac

# --- Required ---
read -rp "$(echo -e "${CYAN}Org token (depuis le dashboard admin):${NC} ")" TOKEN
read -rp "$(echo -e "${CYAN}GHCR token (read:packages):${NC} ")" GHCR
read -rp "$(echo -e "${CYAN}LLM API key:${NC} ")" LLM_KEY
read -rp "$(echo -e "${CYAN}LLM base URL [https://llm.chutes.ai/v1]:${NC} ")" LLM_URL
LLM_URL=${LLM_URL:-https://llm.chutes.ai/v1}

# --- Optional MCPs ---
echo ""
echo -e "${BOLD}MCPs optionnels disponibles:${NC}"
echo "  gmail, drive, calendar, sheets, docs, github, microsoft365, pharmacy, pipedrive, erplain, pennylane"
echo ""
read -rp "$(echo -e "${CYAN}Lesquels activer ? (virgules, ou Enter pour aucun):${NC} ")" MCPS

# --- Build args ---
ARGS="--token ${TOKEN} --ghcr ${GHCR} --llm-key ${LLM_KEY}"

if [[ "$LLM_URL" != "https://llm.chutes.ai/v1" ]]; then
    ARGS="${ARGS} --llm-url ${LLM_URL}"
fi

if [[ -n "$MCPS" ]]; then
    ARGS="${ARGS} --mcps ${MCPS}"

    # Google credentials ?
    NEEDS_GOOGLE=false
    for mcp in ${MCPS//,/ }; do
        case "$mcp" in gmail|drive|calendar|sheets|docs) NEEDS_GOOGLE=true ;; esac
    done

    if [[ "$NEEDS_GOOGLE" == "true" ]]; then
        echo ""
        echo -e "${BOLD}--- Google ---${NC}"
        read -rp "$(echo -e "${CYAN}Mode [1=service_account / 2=oauth]:${NC} ")" GMODE
        case "${GMODE:-1}" in
            1|service_account)
                read -rp "$(echo -e "${CYAN}Chemin du fichier service account JSON (sur la machine client):${NC} ")" SA_PATH
                ARGS="${ARGS} --google-sa-key ${SA_PATH}"
                read -rp "$(echo -e "${CYAN}Email admin Google Workspace:${NC} ")" DRIVE_USER
                if [[ -n "$DRIVE_USER" ]]; then
                    ARGS="${ARGS} --drive-user ${DRIVE_USER}"
                fi
                ;;
            2|oauth)
                read -rp "$(echo -e "${CYAN}Google Client ID:${NC} ")" GID
                read -rp "$(echo -e "${CYAN}Google Client Secret:${NC} ")" GSEC
                ARGS="${ARGS} --google-client-id ${GID} --google-client-secret ${GSEC}"
                ;;
        esac
    fi

    # Microsoft 365 ?
    if echo "$MCPS" | grep -q "microsoft365"; then
        echo ""
        echo -e "${BOLD}--- Microsoft 365 ---${NC}"
        read -rp "$(echo -e "${CYAN}Azure Tenant ID:${NC} ")" MS_TENANT
        read -rp "$(echo -e "${CYAN}Azure Client ID:${NC} ")" MS_CLIENT_ID
        read -rp "$(echo -e "${CYAN}Azure Client Secret:${NC} ")" MS_CLIENT_SECRET
        ARGS="${ARGS} --ms-tenant-id ${MS_TENANT} --ms-client-id ${MS_CLIENT_ID} --ms-client-secret ${MS_CLIENT_SECRET}"
    fi

    # Pipedrive ?
    if echo "$MCPS" | grep -q "pipedrive"; then
        echo ""
        echo -e "${BOLD}--- Pipedrive ---${NC}"
        read -rp "$(echo -e "${CYAN}Pipedrive API token:${NC} ")" PD_TOKEN
        read -rp "$(echo -e "${CYAN}Pipedrive domain (ex: acme):${NC} ")" PD_DOMAIN
        ARGS="${ARGS} --pipedrive-token ${PD_TOKEN} --pipedrive-domain ${PD_DOMAIN}"
    fi

    # Erplain ?
    if echo "$MCPS" | grep -q "erplain"; then
        echo ""
        read -rp "$(echo -e "${CYAN}Erplain API token:${NC} ")" ERP_TOKEN
        ARGS="${ARGS} --erplain-token ${ERP_TOKEN}"
    fi

    # Pennylane ?
    if echo "$MCPS" | grep -q "pennylane"; then
        echo ""
        read -rp "$(echo -e "${CYAN}Pennylane API token:${NC} ")" PL_TOKEN
        ARGS="${ARGS} --pennylane-token ${PL_TOKEN}"
    fi
fi

# --- Output ---
echo ""
echo ""
echo -e "${BOLD}=============================================${NC}"
echo -e "${GREEN}   Commande à envoyer au client${NC}"
echo -e "${BOLD}=============================================${NC}"
echo ""
echo -e "${BOLD}Étape 1 — Avant le call :${NC}"
echo "  Envoyer le fichier wardian-edge-XXXXXXXX.tar.gz"
echo ""

if [[ "$CLIENT_OS" == "windows" ]]; then
    echo -e "${BOLD}Étape 2 — Pré-requis Windows :${NC}"
    echo "  - Docker Desktop installé et lancé (il installe WSL2 automatiquement)"
    echo ""
    echo -e "${BOLD}Étape 3 — Le client ouvre PowerShell et copie-colle :${NC}"
    echo ""
    echo -e "${CYAN}tar xzf wardian-edge-*.tar.gz${NC}"
    echo -e "${CYAN}wsl bash -c \"cd wardian-edge && bash install.sh ${ARGS} -y\"${NC}"
    echo ""
    echo -e "${BOLD}C'est tout.${NC} Ça pull les images (~5 min), démarre, et affiche le statut."
    echo ""
    echo -e "${BOLD}Commandes utiles (PowerShell) :${NC}"
    echo "  docker compose --profile onprem ps         # statut"
    echo "  docker compose --profile onprem logs -f    # logs"
    echo "  docker compose --profile onprem down       # arrêter"
else
    echo -e "${BOLD}Étape 2 — Pendant le call, le client copie-colle :${NC}"
    echo ""
    echo -e "${CYAN}tar xzf wardian-edge-*.tar.gz && cd wardian-edge && bash install.sh ${ARGS} -y${NC}"
    echo ""
    echo -e "${BOLD}C'est tout.${NC} Ça pull les images (~5 min), démarre, et affiche le statut."
fi
echo ""
