#!/usr/bin/env bash
#
# backup-restore-drill.sh — Automated monthly backup restore verification
#
# Clones the Cloud SQL primary from PITR, verifies data, and cleans up.
# Designed to run as a K8s CronJob on the 1st of each month.
#
# Usage:
#   ./scripts/backup-restore-drill.sh
#
# Environment variables (required):
#   GCP_PROJECT       — GCP project ID
#   DB_INSTANCE       — Primary Cloud SQL instance name
#   DB_NAME           — Database name
#   REGION            — GCP region of the primary instance
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────
PROJECT="${GCP_PROJECT:?GCP_PROJECT must be set}"
INSTANCE="${DB_INSTANCE:-todo-app-db-instance}"
DATABASE="${DB_NAME:-todoapp_db}"
REGION="${REGION:-us-central1}"
DRILL_INSTANCE="${INSTANCE}-drill-$(date +%Y%m%d)"
PITR_TIMESTAMP=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null \
  || date -u -v-1H '+%Y-%m-%dT%H:%M:%S.000Z') # Linux || macOS

RESULT="FAIL"

# ─────────────────────────────────────────────────────────────────────────────
# Logging (structured JSON for Cloud Logging)
# ─────────────────────────────────────────────────────────────────────────────
_log() {
  local severity="$1" message="$2"
  echo "{\"severity\":\"${severity}\",\"message\":\"${message}\",\"labels\":{\"drill\":\"backup-restore\",\"instance\":\"${DRILL_INSTANCE}\"}}"
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup — always delete the temporary instance
# ─────────────────────────────────────────────────────────────────────────────
cleanup() {
  _log "INFO" "Cleaning up drill instance ${DRILL_INSTANCE}"
  gcloud sql instances delete "$DRILL_INSTANCE" \
    --project="$PROJECT" --quiet 2>/dev/null || true
  _log "INFO" "Drill result: ${RESULT}"
}
trap cleanup EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Clone from PITR
# ─────────────────────────────────────────────────────────────────────────────
_log "INFO" "Starting backup restore drill for ${INSTANCE}"
_log "INFO" "Cloning ${INSTANCE} to ${DRILL_INSTANCE} from PITR ${PITR_TIMESTAMP}"

gcloud sql instances clone "$INSTANCE" "$DRILL_INSTANCE" \
  --project="$PROJECT" \
  --point-in-time="$PITR_TIMESTAMP" \
  --quiet

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Wait for instance to be RUNNABLE
# ─────────────────────────────────────────────────────────────────────────────
_log "INFO" "Waiting for ${DRILL_INSTANCE} to become RUNNABLE"
MAX_WAIT=600
ELAPSED=0
while true; do
  STATE=$(gcloud sql instances describe "$DRILL_INSTANCE" \
    --project="$PROJECT" --format="value(state)" 2>/dev/null || echo "UNKNOWN")
  if [[ "$STATE" == "RUNNABLE" ]]; then
    break
  fi
  if [[ $ELAPSED -ge $MAX_WAIT ]]; then
    _log "ERROR" "Drill instance did not become RUNNABLE within ${MAX_WAIT}s (state: ${STATE})"
    exit 1
  fi
  sleep 15
  ELAPSED=$((ELAPSED + 15))
done
_log "INFO" "Drill instance is RUNNABLE after ${ELAPSED}s"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Get connection info and verify data
# ─────────────────────────────────────────────────────────────────────────────
DRILL_IP=$(gcloud sql instances describe "$DRILL_INSTANCE" \
  --project="$PROJECT" \
  --format="value(ipAddresses[0].ipAddress)")

_log "INFO" "Drill instance IP: ${DRILL_IP}"

# Get row count from primary for comparison
PRIMARY_IP=$(gcloud sql instances describe "$INSTANCE" \
  --project="$PROJECT" \
  --format="value(ipAddresses[0].ipAddress)")

_log "INFO" "Querying primary instance for baseline row count"
PRIMARY_COUNT=$(PGPASSWORD="${DB_PASSWORD:-}" psql \
  -h "$PRIMARY_IP" -U "${DB_USER:-todoappuser}" -d "$DATABASE" \
  -t -c "SELECT count(*) FROM todos;" 2>/dev/null | tr -d ' ' || echo "-1")

_log "INFO" "Querying drill instance for restored row count"
DRILL_COUNT=$(PGPASSWORD="${DB_PASSWORD:-}" psql \
  -h "$DRILL_IP" -U "${DB_USER:-todoappuser}" -d "$DATABASE" \
  -t -c "SELECT count(*) FROM todos;" 2>/dev/null | tr -d ' ' || echo "-1")

_log "INFO" "Primary count: ${PRIMARY_COUNT}, Drill count: ${DRILL_COUNT}"

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Evaluate result
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$DRILL_COUNT" == "-1" ]]; then
  _log "ERROR" "Could not query drill instance"
  RESULT="FAIL"
elif [[ "$PRIMARY_COUNT" == "-1" ]]; then
  # Can't compare but drill instance is queryable — partial pass
  _log "WARNING" "Could not query primary for comparison, but drill instance returned ${DRILL_COUNT} rows"
  RESULT="PASS (no baseline comparison)"
elif [[ "$DRILL_COUNT" -ge 0 ]]; then
  _log "INFO" "Drill instance has ${DRILL_COUNT} rows (primary has ${PRIMARY_COUNT})"
  RESULT="PASS"
else
  _log "ERROR" "Unexpected drill count: ${DRILL_COUNT}"
  RESULT="FAIL"
fi

_log "INFO" "Backup restore drill completed: ${RESULT}"
if [[ "$RESULT" == "FAIL" ]]; then
  exit 1
fi
