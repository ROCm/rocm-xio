#!/bin/bash
# Create or update rocm-xioGrafana dashboard via the Grafana HTTP API. Run 
# from the grafana directory.
#
# Auth (one of):
#   GRAFANA_API_KEY  - API key (Configuration → API keys → Add API key), or
#   GRAFANA_USER + GRAFANA_PASSWORD - basic auth (e.g. admin / your password).
# Env: GRAFANA_URL (default http://localhost:3000).
# Using overwrite: true updates an existing dashboard with the same UID;
# back up or copy the dashboard first if you have customized it.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PERF_TEST_DIR="$(dirname "$SCRIPT_DIR")"
DASHBOARD_JSON="${PERF_TEST_DIR}/grafana/rocm-xio-dashboard.json"
GRAFANA_URL="${GRAFANA_URL:-http://localhost:3000}"

log() { echo "[$(basename "$0")] $*"; }
die() { log "ERROR: $*"; exit 1; }

if [ -n "${GRAFANA_API_KEY:-}" ]; then
  AUTH_ARG=(-H "Authorization: Bearer $GRAFANA_API_KEY")
elif [ -n "${GRAFANA_USER:-admin}" ] && [ -n "${GRAFANA_PASSWORD:-}" ]; then
  AUTH_ARG=(-u "${GRAFANA_USER}:${GRAFANA_PASSWORD}")
else
  die "Set GRAFANA_API_KEY or both GRAFANA_USER and GRAFANA_PASSWORD."
fi

if [ ! -f "$DASHBOARD_JSON" ]; then
  die "Dashboard JSON not found: $DASHBOARD_JSON"
fi

if ! command -v jq >/dev/null 2>&1; then
  die "jq is required. Install with: sudo apt install jq"
fi

# Build payload: { dashboard: <inner>, overwrite: true }
PAYLOAD="$(jq -c '{dashboard: ., overwrite: true}' "$DASHBOARD_JSON")"
URL="${GRAFANA_URL%/}/api/dashboards/db"

log "POST $URL"
RESP="$(curl -s -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  "${AUTH_ARG[@]}" \
  -d "$PAYLOAD" \
  "$URL")"
HTTP_CODE="$(echo "$RESP" | tail -n1)"
BODY="$(echo "$RESP" | sed '$d')"

if [ "$HTTP_CODE" = "200" ]; then
  log "Dashboard created or updated."
  PATH_SUFFIX="$(echo "$BODY" | jq -r '.url // empty')"
  if [ -n "$PATH_SUFFIX" ]; then
    log "Dashboard URL: ${GRAFANA_URL%/}${PATH_SUFFIX}"
  fi
else
  log "HTTP $HTTP_CODE"
  echo "$BODY" | jq -r '.message // .' 2>/dev/null || echo "$BODY"
  if [ "$HTTP_CODE" = "401" ]; then
    log "Use the Grafana login password (default user is admin; set on first login)."
  fi
  exit 1
fi
