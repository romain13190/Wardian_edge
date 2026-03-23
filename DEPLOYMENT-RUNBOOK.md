# Wardian Edge — Deployment Runbook

Checklist for first-time deployment at a client site.

---

## 1. Prerequisites (client machine)

- [ ] **Docker Engine** 24+ with Compose v2
- [ ] **curl**, **openssl** installed
- [ ] **Python 3.12+** (for `cryptography` Fernet key generation in setup.sh)
- [ ] **Min specs**: 4 vCPU, 8 GB RAM, 50 GB disk (SSD recommended)
- [ ] **OS**: Ubuntu 22.04+, Debian 12+, or RHEL 9+ (any Linux with Docker)

## 2. Network / Firewall

### Outbound required (client → internet)

| Destination | Port | Protocol | Purpose |
|-------------|------|----------|---------|
| `app.wardian.ai` | 443 | WSS | Gateway relay (onprem mode) |
| `llm.chutes.ai` (or custom LLM) | 443 | HTTPS | LLM API calls |
| `ghcr.io` | 443 | HTTPS | Docker image pulls (Watchtower) |
| `*.googleapis.com` | 443 | HTTPS | Gmail, Drive, Calendar (if enabled) |
| `api.pipedrive.com` | 443 | HTTPS | Pipedrive CRM (if enabled) |

### Inbound required

**None.** Wardian Edge is fully outbound-only. The Gateway opens a WebSocket connection outward.

### Internal (between containers)

All inter-container traffic stays on the Docker bridge network. No host ports are exposed by default.

## 3. Pre-deployment validation

```bash
# Check Docker
docker compose version   # must be v2.20+

# Check connectivity to Wardian Cloud
curl -sf https://app.wardian.ai/api/health && echo "OK" || echo "BLOCKED"

# Check connectivity to LLM provider
curl -sf https://llm.chutes.ai/v1/models -H "Authorization: Bearer $LLM_API_KEY" | head -c 200

# Check disk space (need 50 GB min)
df -h /var/lib/docker

# Check available memory (need 8 GB min)
free -h
```

## 4. Run setup

```bash
git clone <edge-repo> wardian-edge && cd wardian-edge
# OR: download and extract the release tarball

./setup.sh
```

The setup script will:
1. Check prerequisites
2. Ask deployment mode (cloud / onprem)
3. Collect org token + cloud URL (onprem) or cloud URL (cloud mode)
4. Collect LLM API key + base URL
5. Ask which MCP servers to enable
6. Collect credentials per provider (Google, Pipedrive, etc.)
7. Generate secure passwords (POSTGRES_PASSWORD, MINIO_ROOT_PASSWORD, INTEGRATION_ENCRYPTION_KEY)
8. Write `.env` and `config/edge.yaml`
9. Pull images and start containers

## 5. Post-startup smoke tests

```bash
# All containers running?
docker compose ps
# Expected: postgres (healthy), minio (healthy), mcp-servers (healthy), knowledge (healthy)
# + gateway (running) if onprem mode

# PostgreSQL accessible?
docker compose exec postgres pg_isready -U wardian -d wardian_edge

# MCP database server responds?
docker compose exec mcp-servers python -c "
import http.client
c = http.client.HTTPConnection('127.0.0.1', 8001, timeout=3)
c.request('GET', '/sse')
r = c.getresponse()
print(f'MCP DB: HTTP {r.status}')
"

# Knowledge engine responds?
docker compose exec knowledge python -c "
import http.client
c = http.client.HTTPConnection('127.0.0.1', 8443, timeout=3)
c.request('GET', '/mcp')
r = c.getresponse()
print(f'Knowledge: HTTP {r.status}')
"

# Gateway connected? (onprem mode only)
docker compose logs gateway --tail 20 | grep -E "Connected|REGISTERED|error"

# MinIO bucket exists?
docker compose exec minio mc alias set local http://localhost:9000 $MINIO_ROOT_USER $MINIO_ROOT_PASSWORD 2>/dev/null
docker compose exec minio mc ls local/wardian-vault
```

## 6. Verify data stays local

```bash
# Upload a test file via the Wardian UI, then verify it's in the local MinIO:
docker compose exec minio mc ls local/wardian-vault --recursive

# Check that no data was sent to cloud S3:
# (verify in Wardian Cloud admin that the org's vault shows 0 files in cloud storage)
```

## 7. Google Workspace validation (if enabled)

### Service account mode
```bash
# Check the service account JSON is mounted:
docker compose exec mcp-servers ls -la /app/config/google-service-account.json

# Check Gmail access (quick test):
docker compose logs mcp-servers | grep -i "gmail\|google\|auth"
```

### Prerequisites for service account mode
1. Google Cloud project created with APIs enabled (Gmail, Drive, Calendar, Sheets, Docs)
2. Service account created with JSON key
3. Domain-wide delegation configured in Google Admin Console
4. Client ID added with required scopes

## 8. Common issues

### Container won't start: "required variable X is missing"
Run `./setup.sh` again — the `.env` file is incomplete.

### Gateway: "SSL certificate verify failed"
The client's network may use a corporate proxy with custom CA. Add to `config/edge.yaml`:
```yaml
ssl_ca_bundle: "/path/to/corporate-ca.pem"
```
Then mount the CA file in docker-compose.yml under the gateway service.

### Knowledge: "connection refused" to MinIO
Check that `minio-init` completed successfully:
```bash
docker compose logs minio-init
```
The bucket must exist before Knowledge can store files.

### MCP servers: "CHUTES_API_KEY not set"
If using the new `LLM_API_KEY` naming, ensure your `.env` has `LLM_API_KEY=...` (not `CHUTES_API_KEY`). Both are supported for backward compatibility.

### Gateway: "token rejected" / "org not found"
- Verify the org token matches what's in the Wardian Cloud admin dashboard
- Ensure the org exists and is active
- Check token hasn't been rotated

### Slow first startup
First boot pulls all Docker images (~5 GB total). Subsequent starts are instant. Knowledge engine also initializes pgvector indexes on first run.

## 9. Monitoring

```bash
# Follow all logs
docker compose logs -f

# Follow specific service
docker compose logs -f knowledge

# Check resource usage
docker stats

# Check disk usage
docker system df
du -sh /var/lib/docker/volumes/wardian-edge_*
```

## 10. Updates

Watchtower checks for new images every 6 hours (if GHCR token configured). To manually update:

```bash
docker compose pull
docker compose up -d
```

## 11. Backup

**Database:**
```bash
docker compose exec postgres pg_dump -U wardian wardian_edge > backup_$(date +%Y%m%d).sql
```

**MinIO (vault files):**
```bash
docker compose exec minio mc mirror local/wardian-vault /tmp/vault-backup
docker cp $(docker compose ps -q minio):/tmp/vault-backup ./vault-backup/
```

**Full backup (volumes):**
```bash
docker compose down
# Backup Docker volumes
sudo tar czf wardian-edge-backup-$(date +%Y%m%d).tar.gz \
  /var/lib/docker/volumes/wardian-edge_edge_pgdata \
  /var/lib/docker/volumes/wardian-edge_edge_s3data
docker compose up -d
```

## 12. Rollback

If an update breaks something:
```bash
# Check Watchtower logs for last update
docker compose logs watchtower | grep -i "update\|pull"

# Rollback to specific image version
docker compose down
# Edit docker-compose.yml to pin image versions (e.g., :v1.2.3 instead of :latest)
docker compose up -d
```

## 13. Shutdown / Decommission

```bash
# Stop (data preserved)
docker compose down

# Stop and DELETE all data (irreversible)
docker compose down -v
```
