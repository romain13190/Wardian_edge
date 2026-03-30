#!/usr/bin/env bash
###############################################################################
# Build the wardian-edge release tarball for client deployment.
#
# Output: wardian-edge-<date>.tar.gz
#
# The tarball contains everything the client needs:
#   wardian-edge/
#   ├── setup.sh              # interactive guided setup
#   ├── install.sh            # non-interactive one-liner
#   ├── docker-compose.yml    # container orchestration
#   ├── init.sql              # database schema
#   ├── .env.example          # reference config
#   └── DEPLOYMENT-RUNBOOK.md # ops runbook
###############################################################################

set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(date +%Y%m%d)
OUTFILE="wardian-edge-${VERSION}.tar.gz"

tar czf "../${OUTFILE}" \
    --transform='s,^,wardian-edge/,' \
    setup.sh \
    install.sh \
    docker-compose.yml \
    init.sql \
    .env.example \
    DEPLOYMENT-RUNBOOK.md

echo "Built: ${OUTFILE} ($(du -h "../${OUTFILE}" | cut -f1))"
echo ""
echo "Send this to the client along with:"
echo "  1. Their org token (from admin dashboard)"
echo "  2. A GHCR read token (for pulling images)"
echo "  3. The LLM API key"
