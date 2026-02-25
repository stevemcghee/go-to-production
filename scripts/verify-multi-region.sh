#!/usr/bin/env bash
#
# verify-multi-region.sh — Milestone 13 multi-region verification
#
# Runs three verification suites for the multi-region deployment:
#   V1: DB replication lag and connectivity
#   V2: DNS and traffic routing
#   V3: Failover drill (optional, causes brief user-facing impact)
#
# Usage:
#   ./scripts/verify-multi-region.sh              # run V1 + V2 (safe)
#   ./scripts/verify-multi-region.sh --all        # run V1 + V2 + V3 (failover drill)
#   ./scripts/verify-multi-region.sh --drill      # run V3 only (failover drill)
#   ./scripts/verify-multi-region.sh --v1         # run V1 only (DB replication)
#   ./scripts/verify-multi-region.sh --v2         # run V2 only (DNS / traffic)
#   ./scripts/verify-multi-region.sh --dry-run    # preview commands without executing
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_FILE="${REPO_ROOT}/.verify-multi-region-$(date +%Y%m%d-%H%M%S).log"
DOMAIN="todo.smig.dev"
MCI_IP="34.160.71.244"

# GCP / Terraform defaults — override with env vars if needed
PROJECT="${GCP_PROJECT:-}"
PRIMARY_REGION="${PRIMARY_REGION:-us-central1}"
SECONDARY_REGION="${SECONDARY_REGION:-us-east1}"
PRIMARY_CLUSTER="${PRIMARY_CLUSTER:-todo-app-cluster}"
SECONDARY_CLUSTER="${SECONDARY_CLUSTER:-todo-app-cluster-secondary}"
DB_INSTANCE="${DB_INSTANCE:-todo-app-db-instance}"
DB_REPLICA="${DB_REPLICA:-todo-app-db-instance-replica}"
NAMESPACE="todo-app"

# Failover drill settings
DRAIN_WAIT_SECONDS=90
RESTORE_WAIT_SECONDS=60

# ─────────────────────────────────────────────────────────────────────────────
# Colors & glyphs
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD='\033[1m'    DIM='\033[2m'     RESET='\033[0m'
  RED='\033[31m'    GREEN='\033[32m'  YELLOW='\033[33m'
  BLUE='\033[34m'   CYAN='\033[36m'
  BG_BLUE='\033[44;97m'  BG_GREEN='\033[42;30m'  BG_RED='\033[41;97m'
else
  BOLD='' DIM='' RESET='' RED='' GREEN='' YELLOW='' BLUE='' CYAN=''
  BG_BLUE='' BG_GREEN='' BG_RED=''
fi

CHECK="✅"  WARN="⚠️ "  BOOM="💥"  MAG="🔍"  DB_ICON="🗄️ "
GLOBE="🌐"  ROCKET="🚀"  CLOCK="⏱️ "

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
_log()    { echo -e "$1" | tee -a "$LOG_FILE"; }
_header() {
  local width=64
  _log ""
  _log "${BG_BLUE} $(printf '%-*s' $width "$1") ${RESET}"
  _log ""
}
_step()   { _log "  ${CYAN}${BOLD}[$1]${RESET} $2"; }
_ok()     { _log "  ${GREEN}${CHECK} $1${RESET}"; }
_warn()   { _log "  ${YELLOW}${WARN} $1${RESET}"; }
_fail()   { _log "  ${RED}${BOOM} $1${RESET}"; }
_info()   { _log "  ${DIM}$ $*${RESET}"; }

DRY_RUN=false

_run() {
  _info "$*"
  if [[ "$DRY_RUN" == "true" ]]; then
    _log "  ${DIM}(dry-run: skipped)${RESET}"
    return 0
  fi
  "$@" 2>&1 | tee -a "$LOG_FILE"
}

_run_quiet() {
  _info "$*"
  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi
  "$@" >> "$LOG_FILE" 2>&1
}

# Track pass/fail counts
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

_pass() { ((PASS_COUNT++)); _ok "$1"; }
_failed() { ((FAIL_COUNT++)); _fail "$1"; }
_skip() { ((SKIP_COUNT++)); _warn "SKIPPED: $1"; }

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisites
# ─────────────────────────────────────────────────────────────────────────────
check_prerequisites() {
  _header "Checking prerequisites"

  local missing=()

  for cmd in gcloud kubectl dig curl jq; do
    if command -v "$cmd" &>/dev/null; then
      _ok "$cmd found"
    else
      missing+=("$cmd")
      _fail "$cmd not found"
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    _fail "Missing required tools: ${missing[*]}"
    _log "  Install them and re-run."
    exit 1
  fi

  # Resolve project ID
  if [[ -z "$PROJECT" ]]; then
    PROJECT=$(gcloud config get-value project 2>/dev/null || true)
    if [[ -z "$PROJECT" ]]; then
      _fail "No GCP project set. Export GCP_PROJECT or run: gcloud config set project <id>"
      exit 1
    fi
  fi
  _ok "GCP project: $PROJECT"

  # Derive kube contexts
  PRIMARY_CTX="gke_${PROJECT}_${PRIMARY_REGION}_${PRIMARY_CLUSTER}"
  SECONDARY_CTX="gke_${PROJECT}_${SECONDARY_REGION}_${SECONDARY_CLUSTER}"

  _log ""
  _log "  ${DIM}Primary context:   $PRIMARY_CTX${RESET}"
  _log "  ${DIM}Secondary context:  $SECONDARY_CTX${RESET}"
  _log "  ${DIM}Log file:           $LOG_FILE${RESET}"
  _log ""
}

# ─────────────────────────────────────────────────────────────────────────────
# V1: DB Replication Verification
# ─────────────────────────────────────────────────────────────────────────────
verify_db_replication() {
  _header "${DB_ICON} V1: Database Replication Verification"

  # 1. Check replica instance exists and is running
  _step "1.1" "Checking replica instance status"
  local replica_state
  replica_state=$(_run gcloud sql instances describe "$DB_REPLICA" \
    --project="$PROJECT" \
    --format="value(state)" 2>/dev/null) || true

  if [[ "$replica_state" == "RUNNABLE" ]]; then
    _pass "Replica $DB_REPLICA is RUNNABLE"
  elif [[ "$DRY_RUN" == "true" ]]; then
    _skip "Dry run — cannot check replica state"
  else
    _failed "Replica $DB_REPLICA state: ${replica_state:-NOT FOUND}"
    return
  fi

  # 2. Check replication lag via Cloud Monitoring
  _step "1.2" "Checking replication lag (Cloud Monitoring)"

  if [[ "$DRY_RUN" == "true" ]]; then
    _skip "Dry run — cannot query monitoring"
  else
    local lag_output
    lag_output=$(gcloud monitoring time-series list \
      --project="$PROJECT" \
      --filter='metric.type="cloudsql.googleapis.com/database/replication/replica_lag" AND resource.labels.database_id="'"$PROJECT:$DB_REPLICA"'"' \
      --limit=1 \
      --format="value(points.value.double_value)" 2>/dev/null) || true

    if [[ -n "$lag_output" ]]; then
      local lag_seconds
      lag_seconds=$(echo "$lag_output" | head -1)
      _log "  ${DIM}Replication lag: ${lag_seconds}s${RESET}"
      # Check if lag is under 10 seconds
      if awk "BEGIN{exit !($lag_seconds < 10)}"; then
        _pass "Replication lag is ${lag_seconds}s (< 10s threshold)"
      else
        _warn "Replication lag is ${lag_seconds}s (>= 10s threshold)"
      fi
    else
      _warn "No replication lag metrics found (replica may be freshly created)"
    fi
  fi

  # 3. Check replica configuration
  _step "1.3" "Checking replica configuration"
  if [[ "$DRY_RUN" == "true" ]]; then
    _skip "Dry run — cannot check replica config"
  else
    local master_name
    master_name=$(gcloud sql instances describe "$DB_REPLICA" \
      --project="$PROJECT" \
      --format="value(masterInstanceName)" 2>/dev/null) || true

    if [[ "$master_name" == *"$DB_INSTANCE"* ]]; then
      _pass "Replica master is $master_name"
    else
      _failed "Replica master mismatch: expected *$DB_INSTANCE*, got $master_name"
    fi

    local replica_region
    replica_region=$(gcloud sql instances describe "$DB_REPLICA" \
      --project="$PROJECT" \
      --format="value(region)" 2>/dev/null) || true

    if [[ "$replica_region" == "$SECONDARY_REGION" ]]; then
      _pass "Replica region is $replica_region"
    else
      _failed "Replica region mismatch: expected $SECONDARY_REGION, got $replica_region"
    fi
  fi

  # 4. Functional replication test (requires Cloud SQL Proxy or direct connectivity)
  _step "1.4" "Functional replication test"
  _log "  ${DIM}This test requires Cloud SQL Proxy running with ports 5432 (primary) and 5433 (replica).${RESET}"
  _log "  ${DIM}If proxy is not running, this step will be skipped.${RESET}"

  if [[ "$DRY_RUN" == "true" ]]; then
    _skip "Dry run — cannot run functional test"
  elif command -v psql &>/dev/null; then
    # Check if primary is reachable on port 5432
    if psql "host=127.0.0.1 port=5432 dbname=todoapp_db sslmode=disable" \
         -c "SELECT 1" &>/dev/null 2>&1; then
      _ok "Primary DB reachable on port 5432"

      # Insert test row
      local test_id="repl-test-$(date +%s)"
      psql "host=127.0.0.1 port=5432 dbname=todoapp_db sslmode=disable" \
        -c "INSERT INTO todos (task, completed) VALUES ('$test_id', false);" >> "$LOG_FILE" 2>&1

      _log "  ${DIM}Inserted test row '$test_id', waiting 5s for replication...${RESET}"
      sleep 5

      # Check replica on port 5433
      local replica_result
      replica_result=$(psql "host=127.0.0.1 port=5433 dbname=todoapp_db sslmode=disable" \
        -t -c "SELECT count(*) FROM todos WHERE task = '$test_id';" 2>/dev/null | tr -d ' ') || true

      if [[ "$replica_result" == "1" ]]; then
        _pass "Replication functional: test row replicated in < 5s"
      else
        _failed "Replication test failed: row not found on replica after 5s"
      fi

      # Clean up
      psql "host=127.0.0.1 port=5432 dbname=todoapp_db sslmode=disable" \
        -c "DELETE FROM todos WHERE task = '$test_id';" >> "$LOG_FILE" 2>&1
      _ok "Test row cleaned up"
    else
      _skip "Cloud SQL Proxy not running on port 5432 — skipping functional test"
      _log "  ${DIM}To run: cloud-sql-proxy --port 5432 $PROJECT:$PRIMARY_REGION:$DB_INSTANCE --port 5433 $PROJECT:$SECONDARY_REGION:$DB_REPLICA${RESET}"
    fi
  else
    _skip "psql not installed — skipping functional replication test"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# V2: DNS & Traffic Routing Verification
# ─────────────────────────────────────────────────────────────────────────────
verify_dns_traffic() {
  _header "${GLOBE} V2: DNS & Traffic Routing Verification"

  # 1. Check MCI static IP
  _step "2.1" "Checking Multi-Cluster Ingress VIP"
  if [[ "$DRY_RUN" == "true" ]]; then
    _skip "Dry run — cannot query MCI"
  else
    local mci_vip
    mci_vip=$(kubectl --context="$PRIMARY_CTX" \
      get mci todo-app-ingress-global -n "$NAMESPACE" \
      -o jsonpath='{.status.VIP}' 2>/dev/null) || true

    if [[ "$mci_vip" == "$MCI_IP" ]]; then
      _pass "MCI VIP is $mci_vip"
    elif [[ -n "$mci_vip" ]]; then
      _warn "MCI VIP is $mci_vip (expected $MCI_IP — update MCI_IP in script if changed)"
    else
      _failed "Could not retrieve MCI VIP (check context: $PRIMARY_CTX)"
    fi
  fi

  # 2. DNS resolution
  _step "2.2" "Checking DNS resolution for $DOMAIN"
  if [[ "$DRY_RUN" == "true" ]]; then
    _skip "Dry run — cannot check DNS"
  else
    local dns_result
    dns_result=$(dig +short "$DOMAIN" 2>/dev/null | head -1) || true

    if [[ "$dns_result" == "$MCI_IP" ]]; then
      _pass "DNS $DOMAIN resolves to $MCI_IP"
    elif [[ -n "$dns_result" ]]; then
      _warn "DNS $DOMAIN resolves to $dns_result (expected $MCI_IP)"
      _log "  ${DIM}Update A record: $DOMAIN → $MCI_IP${RESET}"
    else
      _failed "DNS $DOMAIN does not resolve — A record not configured"
      _log "  ${DIM}Action: point $DOMAIN A record → $MCI_IP${RESET}"
    fi
  fi

  # 3. Health endpoint via domain
  _step "2.3" "Checking health endpoint"
  if [[ "$DRY_RUN" == "true" ]]; then
    _skip "Dry run — cannot curl"
  else
    # Try domain first, fall back to IP
    local health_target="$DOMAIN"
    local health_url="https://${health_target}/healthz"
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 "$health_url" 2>/dev/null) || true

    if [[ "$http_code" == "200" ]]; then
      _pass "Health endpoint returned 200 via $health_target"

      # Get detailed health info
      local health_json
      health_json=$(curl -s --max-time 10 -H "Accept: application/json" "$health_url" 2>/dev/null) || true
      if [[ -n "$health_json" ]]; then
        _log "  ${DIM}Response: $health_json${RESET}"
        local region cluster read_routing
        region=$(echo "$health_json" | jq -r '.region // empty' 2>/dev/null) || true
        cluster=$(echo "$health_json" | jq -r '.cluster // empty' 2>/dev/null) || true
        read_routing=$(echo "$health_json" | jq -r '.read_routing // empty' 2>/dev/null) || true
        [[ -n "$region" ]] && _ok "Serving region: $region"
        [[ -n "$cluster" ]] && _ok "Serving cluster: $cluster"
        [[ -n "$read_routing" ]] && _ok "Read routing: $read_routing"
      fi
    elif [[ "$http_code" == "000" ]]; then
      _warn "Cannot reach $health_url (DNS not configured or TLS issue)"
      _log "  ${DIM}Trying direct IP: $MCI_IP${RESET}"

      http_code=$(curl -sk -o /dev/null -w "%{http_code}" --max-time 10 \
        "https://${MCI_IP}/healthz" -H "Host: $DOMAIN" 2>/dev/null) || true

      if [[ "$http_code" == "200" ]]; then
        _pass "Health endpoint returned 200 via direct IP ($MCI_IP)"
      else
        _failed "Health endpoint returned $http_code via direct IP"
      fi
    else
      _failed "Health endpoint returned HTTP $http_code"
    fi
  fi

  # 4. Backend health on GLB
  _step "2.4" "Checking GLB backend health"
  if [[ "$DRY_RUN" == "true" ]]; then
    _skip "Dry run — cannot query backend services"
  else
    # List backend services that match our app
    local backends
    backends=$(gcloud compute backend-services list \
      --project="$PROJECT" \
      --filter="name~todo" \
      --format="value(name)" 2>/dev/null) || true

    if [[ -n "$backends" ]]; then
      while IFS= read -r backend; do
        _log "  ${DIM}Backend: $backend${RESET}"
        local health_output
        health_output=$(gcloud compute backend-services get-health "$backend" \
          --project="$PROJECT" --global \
          --format="table(status.healthStatus.instance,status.healthStatus.healthState)" 2>/dev/null) || true
        if [[ -n "$health_output" ]]; then
          _log "  ${DIM}$health_output${RESET}"
          if echo "$health_output" | grep -q "HEALTHY"; then
            _pass "Backend $backend has healthy instances"
          else
            _warn "Backend $backend — no HEALTHY instances found"
          fi
        fi
      done <<< "$backends"
    else
      _warn "No 'todo' backend services found — MCI may manage backends differently"
    fi
  fi

  # 5. Check pods in both regions
  _step "2.5" "Checking pod status in both regions"
  for ctx_label in "primary:$PRIMARY_CTX" "secondary:$SECONDARY_CTX"; do
    local label="${ctx_label%%:*}"
    local ctx="${ctx_label#*:}"

    if [[ "$DRY_RUN" == "true" ]]; then
      _skip "Dry run — cannot list pods ($label)"
      continue
    fi

    local pod_count
    pod_count=$(kubectl --context="$ctx" \
      get pods -n "$NAMESPACE" -l app=todo-app-go \
      --field-selector=status.phase=Running \
      --no-headers 2>/dev/null | wc -l | tr -d ' ') || true

    if [[ "$pod_count" -gt 0 ]]; then
      _pass "$label ($ctx): $pod_count running pod(s)"
    else
      _failed "$label ($ctx): no running pods"
    fi
  done
}

# ─────────────────────────────────────────────────────────────────────────────
# V3: Failover Drill
# ─────────────────────────────────────────────────────────────────────────────
verify_failover_drill() {
  _header "${ROCKET} V3: Failover Drill"
  _log ""
  _log "  ${BG_RED} WARNING: This drains us-central1 and causes brief user-facing impact. ${RESET}"
  _log "  ${YELLOW}Run during a maintenance window only.${RESET}"
  _log ""

  if [[ "$DRY_RUN" == "true" ]]; then
    _log "  ${DIM}(dry-run mode — showing commands without executing)${RESET}"
  else
    read -rp "  Type 'yes' to proceed with failover drill: " confirm
    if [[ "$confirm" != "yes" ]]; then
      _warn "Failover drill aborted by user"
      return
    fi
  fi

  # Pre-drill: record baseline
  _step "3.1" "Recording baseline pod counts"
  local primary_pods_before secondary_pods_before
  if [[ "$DRY_RUN" != "true" ]]; then
    primary_pods_before=$(kubectl --context="$PRIMARY_CTX" \
      get pods -n "$NAMESPACE" -l app=todo-app-go \
      --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    secondary_pods_before=$(kubectl --context="$SECONDARY_CTX" \
      get pods -n "$NAMESPACE" -l app=todo-app-go \
      --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
    _ok "Primary pods: $primary_pods_before, Secondary pods: $secondary_pods_before"
  else
    _skip "Dry run — skipping baseline"
    primary_pods_before=2
  fi

  # Drain primary: scale to 0
  _step "3.2" "Draining $PRIMARY_REGION — scaling rollout to 0 replicas"
  if [[ "$DRY_RUN" == "true" ]]; then
    _info "kubectl --context=$PRIMARY_CTX scale rollout todo-app-go --replicas=0 -n $NAMESPACE"
    _skip "Dry run — not scaling"
  else
    kubectl --context="$PRIMARY_CTX" \
      argo rollouts set-replicas todo-app-go 0 -n "$NAMESPACE" 2>/dev/null \
    || kubectl --context="$PRIMARY_CTX" \
      scale rollout todo-app-go --replicas=0 -n "$NAMESPACE" 2>/dev/null \
    || kubectl --context="$PRIMARY_CTX" \
      scale deployment todo-app-go --replicas=0 -n "$NAMESPACE" 2>/dev/null \
    || { _failed "Could not scale down primary"; return; }

    _ok "Primary scaled to 0"
  fi

  # Wait for GLB health checks to detect the change
  _step "3.3" "Waiting ${DRAIN_WAIT_SECONDS}s for GLB to detect drain"
  if [[ "$DRY_RUN" != "true" ]]; then
    local elapsed=0
    while [[ $elapsed -lt $DRAIN_WAIT_SECONDS ]]; do
      printf "\r  ${DIM}${CLOCK} %ds / %ds${RESET}" "$elapsed" "$DRAIN_WAIT_SECONDS"
      sleep 5
      elapsed=$((elapsed + 5))
    done
    printf "\r  ${DIM}${CLOCK} %ds / %ds${RESET}\n" "$DRAIN_WAIT_SECONDS" "$DRAIN_WAIT_SECONDS"
  else
    _skip "Dry run — not waiting"
  fi

  # Verify secondary is serving
  _step "3.4" "Verifying $SECONDARY_REGION is serving traffic"
  if [[ "$DRY_RUN" == "true" ]]; then
    _skip "Dry run — cannot verify"
  else
    local attempts=0
    local max_attempts=6
    local failover_ok=false

    while [[ $attempts -lt $max_attempts ]]; do
      local http_code
      http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
        "https://${DOMAIN}/healthz" 2>/dev/null) || true

      if [[ "$http_code" == "200" ]]; then
        # Check which region is serving
        local health_json
        health_json=$(curl -s --max-time 10 -H "Accept: application/json" \
          "https://${DOMAIN}/healthz" 2>/dev/null) || true
        local serving_region
        serving_region=$(echo "$health_json" | jq -r '.region // empty' 2>/dev/null) || true

        _pass "HTTP 200 from region: ${serving_region:-unknown}"
        failover_ok=true
        break
      fi

      attempts=$((attempts + 1))
      _log "  ${DIM}Attempt $attempts/$max_attempts: HTTP $http_code — retrying in 15s...${RESET}"
      sleep 15
    done

    if [[ "$failover_ok" == "true" ]]; then
      _pass "FAILOVER SUCCESS: $SECONDARY_REGION is serving traffic"
    else
      _failed "FAILOVER FAILED: could not reach service after ${DRAIN_WAIT_SECONDS}s + retries"
    fi
  fi

  # Verify reads work
  _step "3.5" "Verifying read requests from $SECONDARY_REGION"
  if [[ "$DRY_RUN" == "true" ]]; then
    _skip "Dry run — cannot verify reads"
  else
    local todos_response
    todos_response=$(curl -s --max-time 10 \
      -H "Accept: application/json" \
      "https://${DOMAIN}/" 2>/dev/null) || true

    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 10 \
      "https://${DOMAIN}/" 2>/dev/null) || true

    if [[ "$http_code" == "200" ]]; then
      _pass "Read requests succeeding (HTTP $http_code)"
    else
      _failed "Read requests failing (HTTP $http_code)"
    fi
  fi

  # Restore primary
  _step "3.6" "Restoring $PRIMARY_REGION — scaling back to $primary_pods_before replicas"
  if [[ "$DRY_RUN" == "true" ]]; then
    _info "kubectl --context=$PRIMARY_CTX scale rollout todo-app-go --replicas=$primary_pods_before -n $NAMESPACE"
    _skip "Dry run — not restoring"
  else
    kubectl --context="$PRIMARY_CTX" \
      argo rollouts set-replicas todo-app-go "$primary_pods_before" -n "$NAMESPACE" 2>/dev/null \
    || kubectl --context="$PRIMARY_CTX" \
      scale rollout todo-app-go --replicas="$primary_pods_before" -n "$NAMESPACE" 2>/dev/null \
    || kubectl --context="$PRIMARY_CTX" \
      scale deployment todo-app-go --replicas="$primary_pods_before" -n "$NAMESPACE" 2>/dev/null \
    || { _failed "Could not restore primary — MANUAL INTERVENTION NEEDED"; return; }

    _ok "Primary scaling back to $primary_pods_before replicas"
  fi

  # Wait for restore
  _step "3.7" "Waiting ${RESTORE_WAIT_SECONDS}s for primary to stabilize"
  if [[ "$DRY_RUN" != "true" ]]; then
    local elapsed=0
    while [[ $elapsed -lt $RESTORE_WAIT_SECONDS ]]; do
      printf "\r  ${DIM}${CLOCK} %ds / %ds${RESET}" "$elapsed" "$RESTORE_WAIT_SECONDS"
      sleep 5
      elapsed=$((elapsed + 5))
    done
    printf "\r  ${DIM}${CLOCK} %ds / %ds${RESET}\n" "$RESTORE_WAIT_SECONDS" "$RESTORE_WAIT_SECONDS"
  else
    _skip "Dry run — not waiting"
  fi

  # Verify both regions healthy post-restore
  _step "3.8" "Verifying both regions restored"
  if [[ "$DRY_RUN" == "true" ]]; then
    _skip "Dry run — cannot verify restore"
  else
    for ctx_label in "primary:$PRIMARY_CTX" "secondary:$SECONDARY_CTX"; do
      local label="${ctx_label%%:*}"
      local ctx="${ctx_label#*:}"
      local pod_count
      pod_count=$(kubectl --context="$ctx" \
        get pods -n "$NAMESPACE" -l app=todo-app-go \
        --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')

      if [[ "$pod_count" -gt 0 ]]; then
        _pass "$label: $pod_count running pod(s)"
      else
        _warn "$label: pods not yet ready (may need more time)"
      fi
    done
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
print_summary() {
  _log ""
  local total=$((PASS_COUNT + FAIL_COUNT + SKIP_COUNT))
  if [[ $FAIL_COUNT -eq 0 ]]; then
    _header "${CHECK} Verification Complete — All Checks Passed"
  else
    _header "${BOOM} Verification Complete — $FAIL_COUNT check(s) failed"
  fi
  _log "  ${GREEN}Passed: $PASS_COUNT${RESET}  ${RED}Failed: $FAIL_COUNT${RESET}  ${YELLOW}Skipped: $SKIP_COUNT${RESET}  Total: $total"
  _log ""
  _log "  ${DIM}Full log: $LOG_FILE${RESET}"
  _log ""

  if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
main() {
  local run_v1=false run_v2=false run_v3=false

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --v1)       run_v1=true ;;
      --v2)       run_v2=true ;;
      --drill|--v3) run_v3=true ;;
      --all)      run_v1=true; run_v2=true; run_v3=true ;;
      --dry-run)  DRY_RUN=true ;;
      --help|-h)
        echo "Usage: $0 [--v1] [--v2] [--drill|--v3] [--all] [--dry-run]"
        echo ""
        echo "  --v1       Run V1: DB replication checks"
        echo "  --v2       Run V2: DNS & traffic routing checks"
        echo "  --drill    Run V3: Failover drill (causes brief downtime)"
        echo "  --all      Run all verifications (V1 + V2 + V3)"
        echo "  --dry-run  Preview commands without executing"
        echo ""
        echo "Default (no flags): runs V1 + V2 (safe, no impact)"
        exit 0
        ;;
      *)
        echo "Unknown option: $1 (use --help for usage)"
        exit 1
        ;;
    esac
    shift
  done

  # Default: V1 + V2 if nothing specified
  if [[ "$run_v1" == "false" && "$run_v2" == "false" && "$run_v3" == "false" ]]; then
    run_v1=true
    run_v2=true
  fi

  _header "${MAG} Milestone 13 — Multi-Region Verification"
  _log "  ${DIM}Date: $(date)${RESET}"
  [[ "$DRY_RUN" == "true" ]] && _log "  ${YELLOW}DRY-RUN MODE — no changes will be made${RESET}"

  check_prerequisites

  [[ "$run_v1" == "true" ]] && verify_db_replication
  [[ "$run_v2" == "true" ]] && verify_dns_traffic
  [[ "$run_v3" == "true" ]] && verify_failover_drill

  print_summary
}

main "$@"
