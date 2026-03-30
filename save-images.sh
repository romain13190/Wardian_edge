#!/usr/bin/env bash
###############################################################################
# Sauvegarde toutes les images Docker de Wardian Edge dans un fichier.
#
# Utilisation :
#   bash save-images.sh          # → wardian-edge-images.tar.gz (~2-3 GB)
#
# Le client charge les images sans internet :
#   docker load < wardian-edge-images.tar.gz
###############################################################################

set -euo pipefail

IMAGES=(
    "ghcr.io/romain13190/wardian-mcp-servers:latest"
    "ghcr.io/romain13190/wardian-knowledge:latest"
    "ghcr.io/romain13190/wardian-gateway:latest"
    "pgvector/pgvector:pg16"
    "minio/minio:latest"
    "minio/mc:latest"
    "containrrr/watchtower:latest"
)

OUTFILE="wardian-edge-images.tar.gz"

echo "Pulling latest images..."
for img in "${IMAGES[@]}"; do
    echo "  pulling $img"
    docker pull "$img"
done

echo ""
echo "Saving to ${OUTFILE} (this takes a few minutes)..."
docker save "${IMAGES[@]}" | gzip > "$OUTFILE"

echo ""
SIZE=$(du -h "$OUTFILE" | cut -f1)
echo "Done: ${OUTFILE} (${SIZE})"
echo ""
echo "Pour le client (sans internet) :"
echo "  docker load < ${OUTFILE}"
