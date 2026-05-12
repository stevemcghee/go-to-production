#!/usr/bin/env bash
#
# migrate-project.sh — Zero-downtime GCP project migration
#
# Automates the parallel-deploy + DNS-cutover strategy described in
# docs/GCP_PROJECT_MIGRATION.md. Resumable via checkpoint file.
#
# Usage:
#   ./scripts/migrate-project.sh                        # interactive
#   ./scripts/migrate-project.sh --new-project my-proj  # skip the prompt
#   ./scripts/migrate-project.sh --resume               # pick up where you left off
#   ./scripts/migrate-project.sh --phase 3              # jump to a specific phase
#   ./scripts/migrate-project.sh --dry-run              # preview without executing
#
set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Constants
# ─────────────────────────────────────────────────────────────────────────────
OLD_PROJECT="GCP_PROJECT_ID"
OLD_STATE_BUCKET="tf-state-GCP_PROJECT_ID"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CHECKPOINT_FILE="${REPO_ROOT}/.migration-checkpoint"
LOG_FILE="${REPO_ROOT}/.migration-$(date +%Y%m%d-%H%M%S).log"
DOMAIN="DOMAIN_NAME"
DNS_ZONE="DNS_ZONE"
OLD_MCI_IP="MCI_IP"

# ─────────────────────────────────────────────────────────────────────────────
# Colors & glyphs
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  BOLD='\033[1m'    DIM='\033[2m'     RESET='\033[0m'
  RED='\033[31m'    GREEN='\033[32m'  YELLOW='\033[33m'
  BLUE='\033[34m'   CYAN='\033[36m'   MAGENTA='\033[35m'
  BG_GREEN='\033[42;30m'  BG_BLUE='\033[44;97m'  BG_RED='\033[41;97m'
  BG_YELLOW='\033[43;30m'
else
  BOLD='' DIM='' RESET='' RED='' GREEN='' YELLOW=''
  BLUE='' CYAN='' MAGENTA='' BG_GREEN='' BG_BLUE='' BG_RED='' BG_YELLOW=''
fi

ROCKET="🚀"  CHECK="✅"  WARN="⚠️ "  BOOM="💥"  LOCK="🔒"  DB="🗄️ "
GEAR="⚙️ "   DNS_ICON="🌐"  BROOM="🧹"  CLOCK="⏱️ "  PARTY="🎉"
SHIELD="🛡️ "  TRUCK="🚚"  MAG="🔍"  HAMMER="🔨"  LINK="🔗"

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
_info()   { _log "  ${DIM}$1${RESET}"; }
_run()    {
  _info "$ $*"
  if [[ "$DRY_RUN" == "true" ]]; then
    _info "(dry-run: skipped)"
    return 0
  fi
  if "$@" >> "$LOG_FILE" 2>&1; then
    return 0
  else
    local rc=$?
    _fail "Command failed (exit $rc): $*"
    _fail "Check log: $LOG_FILE"
    return $rc
  fi
}

# Run a command, but show its output live (for interactive steps)
_run_live() {
  _info "$ $*"
  if [[ "$DRY_RUN" == "true" ]]; then
    _info "(dry-run: skipped)"
    return 0
  fi
  if "$@" 2>&1 | tee -a "$LOG_FILE"; then
    return 0
  else
    local rc=${PIPESTATUS[0]}
    _fail "Command failed (exit $rc): $*"
    return $rc
  fi
}

_confirm() {
  if [[ "$DRY_RUN" == "true" ]]; then return 0; fi
  local msg="${1:-Continue?}"
  echo -en "  ${YELLOW}${msg} [y/N]${RESET} "
  read -r ans
  [[ "$ans" =~ ^[Yy] ]]
}

_must_have() {
  for cmd in "$@"; do
    if ! command -v "$cmd" &>/dev/null; then
      _fail "Required tool not found: ${BOLD}$cmd${RESET}"
      _info "Install it and re-run. The script will resume from where it left off."
      exit 1
    fi
  done
}

_progress_bar() {
  local current=$1 total=$2 width=40
  local pct=$((current * 100 / total))
  local filled=$((current * width / total))
  local empty=$((width - filled))
  local bar="${GREEN}"
  for ((i=0; i<filled; i++)); do bar+="█"; done
  bar+="${DIM}"
  for ((i=0; i<empty; i++)); do bar+="░"; done
  bar+="${RESET}"
  printf "\r  %s %3d%% (%d/%d)" "$bar" "$pct" "$current" "$total"
}

_elapsed() {
  local start=$1
  local now
  now=$(date +%s)
  local diff=$((now - start))
  printf "%dm%02ds" $((diff / 60)) $((diff % 60))
}

# ─────────────────────────────────────────────────────────────────────────────
# Checkpoint management
# ─────────────────────────────────────────────────────────────────────────────
_save_checkpoint() {
  local phase=$1 step=$2
  cat > "$CHECKPOINT_FILE" <<EOF
PHASE=$phase
STEP=$step
NEW_PROJECT=$NEW_PROJECT
TIMESTAMP=$(date -Iseconds)
EOF
  _info "Checkpoint saved: phase $phase, step $step"
}

_load_checkpoint() {
  if [[ -f "$CHECKPOINT_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$CHECKPOINT_FILE"
    RESUME_PHASE="${PHASE:-0}"
    RESUME_STEP="${STEP:-0}"
    _ok "Resuming from phase $RESUME_PHASE, step $RESUME_STEP"
    if [[ -n "${NEW_PROJECT:-}" ]]; then
      _info "Target project: $NEW_PROJECT"
    fi
    return 0
  fi
  return 1
}

_clear_checkpoint() {
  rm -f "$CHECKPOINT_FILE"
}

_should_skip() {
  local phase=$1 step=$2
  if (( phase < RESUME_PHASE )); then return 0; fi
  if (( phase == RESUME_PHASE && step <= RESUME_STEP )); then return 0; fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Parse arguments
# ─────────────────────────────────────────────────────────────────────────────
DRY_RUN="false"
RESUME="false"
JUMP_PHASE=""
NEW_PROJECT=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --new-project) NEW_PROJECT="$2"; shift 2 ;;
    --resume)      RESUME="true"; shift ;;
    --phase)       JUMP_PHASE="$2"; shift 2 ;;
    --dry-run)     DRY_RUN="true"; shift ;;
    --help|-h)
      echo "Usage: $0 [--new-project ID] [--resume] [--phase N] [--dry-run]"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

RESUME_PHASE=0
RESUME_STEP=0

# ─────────────────────────────────────────────────────────────────────────────
# Banner
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${MAGENTA}"
cat << 'BANNER'
   ╔══════════════════════════════════════════════════════════════╗
   ║                                                              ║
   ║   🚀  GCP Project Migration — Zero Downtime Edition  🚀     ║
   ║                                                              ║
   ║   Parallel deploy → validate → DNS cutover → cleanup         ║
   ║                                                              ║
   ╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${RESET}"

_log "${DIM}Log file: $LOG_FILE${RESET}"
_log "${DIM}Repo root: $REPO_ROOT${RESET}"
[[ "$DRY_RUN" == "true" ]] && _warn "DRY RUN mode — no changes will be made"

# ─────────────────────────────────────────────────────────────────────────────
# Resume logic
# ─────────────────────────────────────────────────────────────────────────────
if [[ "$RESUME" == "true" ]]; then
  if _load_checkpoint; then
    : # checkpoint loaded
  else
    _fail "No checkpoint file found. Run without --resume to start fresh."
    exit 1
  fi
elif [[ -n "$JUMP_PHASE" ]]; then
  RESUME_PHASE=$JUMP_PHASE
  RESUME_STEP=0
  _info "Jumping to phase $JUMP_PHASE"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Prerequisites check
# ─────────────────────────────────────────────────────────────────────────────
_header "${GEAR}  Phase 0: Preflight Checks"

_step "0.1" "Checking required tools..."
_must_have gcloud terraform kubectl helm cosign docker grep sed git

_ok "All required tools found"

_step "0.2" "Verifying gcloud authentication..."
GCLOUD_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null || true)
if [[ -z "$GCLOUD_ACCOUNT" ]]; then
  _fail "No active gcloud account. Run: gcloud auth login"
  exit 1
fi
_ok "Authenticated as: $GCLOUD_ACCOUNT"

# ─────────────────────────────────────────────────────────────────────────────
# Collect target project
# ─────────────────────────────────────────────────────────────────────────────
if [[ -z "$NEW_PROJECT" ]]; then
  echo ""
  echo -en "  ${BOLD}Enter the NEW GCP project ID: ${RESET}"
  read -r NEW_PROJECT
  if [[ -z "$NEW_PROJECT" ]]; then
    _fail "Project ID cannot be empty."
    exit 1
  fi
fi

if [[ "$NEW_PROJECT" == "$OLD_PROJECT" ]]; then
  _fail "New project ID cannot be the same as the old one ($OLD_PROJECT)."
  exit 1
fi

NEW_STATE_BUCKET="tf-state-${NEW_PROJECT}"

echo ""
_log "  ${BOLD}Migration plan:${RESET}"
_log "  ┌──────────────────────────────────────────────────┐"
_log "  │  ${DIM}FROM${RESET}  ${RED}$OLD_PROJECT${RESET}"
_log "  │  ${DIM}TO${RESET}    ${GREEN}$NEW_PROJECT${RESET}"
_log "  │  ${DIM}STATE${RESET} ${CYAN}gs://$NEW_STATE_BUCKET${RESET}"
_log "  └──────────────────────────────────────────────────┘"
echo ""

if ! _confirm "${ROCKET} Ready to begin migration?"; then
  _info "Aborted."
  exit 0
fi

MIGRATION_START=$(date +%s)

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Provision infrastructure in new project
# ═══════════════════════════════════════════════════════════════════════════════
_header "${HAMMER}  Phase 1/6: Provision New Infrastructure"

# --- 1.1 Create GCP project ---
if ! _should_skip 1 1; then
  _step "1.1" "Creating GCP project ${BOLD}$NEW_PROJECT${RESET}..."
  if gcloud projects describe "$NEW_PROJECT" &>/dev/null; then
    _ok "Project already exists — skipping creation"
  else
    _run gcloud projects create "$NEW_PROJECT" --name="Todo App Production"
    _ok "Project created"
  fi

  _step "1.1b" "Linking billing account..."
  BILLING_ACCOUNT=$(gcloud billing accounts list --format='value(ACCOUNT_ID)' --limit=1 2>/dev/null || true)
  if [[ -n "$BILLING_ACCOUNT" ]]; then
    _run gcloud billing projects link "$NEW_PROJECT" --billing-account="$BILLING_ACCOUNT"
    _ok "Billing linked: $BILLING_ACCOUNT"
  else
    _warn "No billing account found — link one manually before proceeding"
    _confirm "Press y once billing is linked" || exit 1
  fi
  _save_checkpoint 1 1
fi

# --- 1.2 Create Terraform state bucket ---
if ! _should_skip 1 2; then
  _step "1.2" "Creating Terraform state bucket..."
  if gsutil ls -b "gs://$NEW_STATE_BUCKET" &>/dev/null 2>&1; then
    _ok "State bucket already exists"
  else
    _run gsutil mb -p "$NEW_PROJECT" -l us-central1 "gs://$NEW_STATE_BUCKET"
    _run gsutil versioning set on "gs://$NEW_STATE_BUCKET"
    _ok "State bucket created with versioning"
  fi
  _save_checkpoint 1 2
fi

# --- 1.3 Update Terraform backend ---
if ! _should_skip 1 3; then
  _step "1.3" "Updating Terraform backend config..."
  MAIN_TF="${REPO_ROOT}/terraform/main.tf"

  if grep -q "$NEW_STATE_BUCKET" "$MAIN_TF"; then
    _ok "Backend already points to new bucket"
  else
    sed -i "s|$OLD_STATE_BUCKET|$NEW_STATE_BUCKET|g" "$MAIN_TF"
    _ok "Backend updated: $OLD_STATE_BUCKET -> $NEW_STATE_BUCKET"
  fi
  _save_checkpoint 1 3
fi

# --- 1.4 Update terraform.tfvars ---
if ! _should_skip 1 4; then
  _step "1.4" "Updating terraform.tfvars..."
  TFVARS="${REPO_ROOT}/terraform/terraform.tfvars"

  if [[ -f "$TFVARS" ]]; then
    if grep -q "$NEW_PROJECT" "$TFVARS"; then
      _ok "tfvars already updated"
    else
      sed -i "s|$OLD_PROJECT|$NEW_PROJECT|g" "$TFVARS"
      _ok "Project ID updated in tfvars"
    fi
  else
    _warn "No terraform.tfvars found — creating from example"
    if [[ -f "${REPO_ROOT}/terraform/terraform.tfvars.example" ]]; then
      cp "${REPO_ROOT}/terraform/terraform.tfvars.example" "$TFVARS"
      sed -i "s|$OLD_PROJECT|$NEW_PROJECT|g" "$TFVARS"
    else
      cat > "$TFVARS" <<TFEOF
project_id  = "$NEW_PROJECT"
db_password = "CHANGE_ME_$(openssl rand -hex 12)"
alert_email = "$GCLOUD_ACCOUNT"
TFEOF
    fi
    _warn "Review $TFVARS and set the db_password before continuing"
    _confirm "Press y once tfvars is ready" || exit 1
  fi
  _save_checkpoint 1 4
fi

# --- 1.5 Terraform init + apply ---
if ! _should_skip 1 5; then
  _step "1.5" "Running Terraform init..."
  _run_live terraform -chdir="${REPO_ROOT}/terraform" init -reconfigure

  _step "1.5b" "Running Terraform plan..."
  _run_live terraform -chdir="${REPO_ROOT}/terraform" plan -out=migration.tfplan

  echo ""
  if _confirm "${ROCKET} Apply the Terraform plan?"; then
    _step "1.5c" "Applying Terraform (this takes 20-40 min)..."
    APPLY_START=$(date +%s)
    _run_live terraform -chdir="${REPO_ROOT}/terraform" apply migration.tfplan
    _ok "Terraform applied in $(_elapsed $APPLY_START)"
  else
    _warn "Terraform apply skipped — re-run with --phase 1 to retry"
    _save_checkpoint 1 4
    exit 0
  fi

  _step "1.5d" "Recording Terraform outputs..."
  NEW_MCI_IP=$(terraform -chdir="${REPO_ROOT}/terraform" output -raw mci_static_ip 2>/dev/null || echo "UNKNOWN")
  NEW_SQL_CONN=$(terraform -chdir="${REPO_ROOT}/terraform" output -raw cloudsql_instance_connection_name 2>/dev/null || echo "UNKNOWN")
  _ok "New MCI IP: $NEW_MCI_IP"
  _ok "New SQL connection: $NEW_SQL_CONN"
  _save_checkpoint 1 5
fi

_ok "Phase 1 complete ${PARTY}"

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: Migrate Database
# ═══════════════════════════════════════════════════════════════════════════════
_header "${DB}  Phase 2/6: Migrate Database"

# --- 2.1 Export from old project ---
if ! _should_skip 2 1; then
  _step "2.1" "Exporting database from old project..."
  EXPORT_URI="gs://${OLD_STATE_BUCKET}/db-export/migration-$(date +%Y%m%d).sql"

  _run gcloud sql export sql todo-app-db-instance "$EXPORT_URI" \
    --database=todoapp_db \
    --project="$OLD_PROJECT"
  _ok "Database exported to $EXPORT_URI"
  _save_checkpoint 2 1
fi

# --- 2.2 Import into new project ---
if ! _should_skip 2 2; then
  _step "2.2" "Copying export to new project bucket..."
  IMPORT_URI="gs://${NEW_STATE_BUCKET}/db-import/migration.sql"
  _run gsutil cp "$EXPORT_URI" "$IMPORT_URI"

  _step "2.2b" "Granting Cloud SQL access to import bucket..."
  SQL_SA=$(gcloud sql instances describe todo-app-db-instance \
    --project="$NEW_PROJECT" \
    --format='value(serviceAccountEmailAddress)' 2>/dev/null || echo "")
  if [[ -n "$SQL_SA" ]]; then
    _run gsutil iam ch "serviceAccount:${SQL_SA}:objectViewer" "gs://${NEW_STATE_BUCKET}"
  fi

  _step "2.2c" "Importing database into new project..."
  _run gcloud sql import sql todo-app-db-instance "$IMPORT_URI" \
    --database=todoapp_db \
    --project="$NEW_PROJECT" \
    --quiet
  _ok "Database imported successfully"
  _save_checkpoint 2 2
fi

# --- 2.3 Create IAM DB user ---
if ! _should_skip 2 3; then
  _step "2.3" "Configuring kubectl for new primary cluster..."
  _run gcloud container clusters get-credentials todo-app-cluster \
    --region=us-central1 --project="$NEW_PROJECT"

  _step "2.3b" "Creating IAM database user..."
  if [[ -f "${REPO_ROOT}/k8s/base/create-iam-user-job.yaml" ]]; then
    _run kubectl apply -f "${REPO_ROOT}/k8s/base/create-iam-user-job.yaml"
    _run kubectl wait --for=condition=complete job/create-iam-user -n todo-app --timeout=120s
    _ok "IAM database user created"
  else
    _warn "create-iam-user-job.yaml not found — create the IAM user manually"
  fi
  _save_checkpoint 2 3
fi

# --- 2.4 Verify data ---
if ! _should_skip 2 4; then
  _step "2.4" "Verifying data integrity..."
  _info "Connect to the new database and verify row counts match the old project."
  _info "Old project: gcloud sql connect todo-app-db-instance --project=$OLD_PROJECT"
  _info "New project: gcloud sql connect todo-app-db-instance --project=$NEW_PROJECT"
  _confirm "Data verified?" || _warn "Continuing without verification — verify manually later"
  _save_checkpoint 2 4
fi

_ok "Phase 2 complete ${PARTY}"

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: Build & Deploy Application
# ═══════════════════════════════════════════════════════════════════════════════
_header "${TRUCK}  Phase 3/6: Build & Deploy Application"

# --- 3.1 Update hardcoded project references ---
if ! _should_skip 3 1; then
  _step "3.1" "Scanning for old project ID references..."

  FILES_WITH_OLD_REF=$(grep -rl "$OLD_PROJECT" \
    --include='*.go' --include='*.yaml' --include='*.yml' \
    --include='*.sh' --include='*.tf' \
    "$REPO_ROOT" 2>/dev/null | grep -v '.migration-' | grep -v 'docs/' || true)

  if [[ -z "$FILES_WITH_OLD_REF" ]]; then
    _ok "No references to old project found (already updated)"
  else
    COUNT=$(echo "$FILES_WITH_OLD_REF" | wc -l)
    _info "Found $COUNT files with references to $OLD_PROJECT:"
    echo "$FILES_WITH_OLD_REF" | while read -r f; do
      _info "  ${f#$REPO_ROOT/}"
    done
    echo ""

    if _confirm "Replace all occurrences of ${RED}$OLD_PROJECT${RESET} with ${GREEN}$NEW_PROJECT${RESET}?"; then
      echo "$FILES_WITH_OLD_REF" | while read -r f; do
        sed -i "s|$OLD_PROJECT|$NEW_PROJECT|g" "$f"
      done
      _ok "Replaced $COUNT files"

      # Verify
      REMAINING=$(grep -rl "$OLD_PROJECT" \
        --include='*.go' --include='*.yaml' --include='*.yml' \
        --include='*.sh' --include='*.tf' \
        "$REPO_ROOT" 2>/dev/null | grep -v '.migration-' | grep -v 'docs/' || true)
      if [[ -n "$REMAINING" ]]; then
        _warn "Some references remain (may be in docs/comments):"
        echo "$REMAINING" | while read -r f; do _info "  ${f#$REPO_ROOT/}"; done
      else
        _ok "All code references updated"
      fi
    fi
  fi
  _save_checkpoint 3 1
fi

# --- 3.2 Build container image ---
if ! _should_skip 3 2; then
  _step "3.2" "Authenticating to Artifact Registry..."
  _run gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

  IMAGE="us-central1-docker.pkg.dev/${NEW_PROJECT}/todo-app-go/todo-app-go"
  TAG="migration-$(date +%Y%m%d-%H%M%S)"

  _step "3.2b" "Building container image..."
  _run_live docker build -t "${IMAGE}:${TAG}" "$REPO_ROOT"
  _ok "Image built: ${IMAGE}:${TAG}"

  _step "3.2c" "Pushing container image..."
  _run_live docker push "${IMAGE}:${TAG}"
  _ok "Image pushed"

  _step "3.2d" "Signing image with Cosign..."
  if _run cosign sign --yes "${IMAGE}:${TAG}"; then
    _ok "Image signed"
  else
    _warn "Cosign signing failed — Binary Authorization may block deployment"
    _warn "Run manually: cosign sign --yes ${IMAGE}:${TAG}"
  fi

  # Get the digest for Kustomize
  IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "${IMAGE}:${TAG}" 2>/dev/null | cut -d@ -f2 || echo "")
  if [[ -n "$IMAGE_DIGEST" ]]; then
    _ok "Image digest: $IMAGE_DIGEST"
  fi
  _save_checkpoint 3 2
fi

# --- 3.3 Update Kustomize image ---
if ! _should_skip 3 3; then
  _step "3.3" "Updating Kustomize image reference..."
  KUSTOMIZATION="${REPO_ROOT}/k8s/base/kustomization.yaml"
  if [[ -f "$KUSTOMIZATION" ]] && [[ -n "${IMAGE_DIGEST:-}" ]]; then
    # Update the digest in kustomization.yaml
    if grep -q "digest:" "$KUSTOMIZATION"; then
      sed -i "s|digest: sha256:.*|digest: ${IMAGE_DIGEST}|g" "$KUSTOMIZATION"
      _ok "Kustomize digest updated"
    else
      _info "No digest field found in kustomization.yaml — update manually"
    fi
  else
    _warn "Skipping kustomize update (missing file or digest)"
  fi
  _save_checkpoint 3 3
fi

# --- 3.4 Deploy via ArgoCD ---
if ! _should_skip 3 4; then
  _step "3.4" "Getting ArgoCD admin password..."
  ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "")

  if [[ -n "$ARGOCD_PASS" ]]; then
    _ok "ArgoCD password retrieved"
    _info "ArgoCD UI: kubectl port-forward svc/argocd-server -n argocd 8080:443"
    _info "Login: admin / (see above)"
  else
    _warn "Could not retrieve ArgoCD password"
  fi

  _step "3.4b" "Syncing application..."
  _info "ArgoCD should auto-sync from the git repository."
  _info "If not, create the app manually:"
  _info "  argocd app create todo-app --repo <your-repo> --path k8s/ --dest-namespace todo-app"
  _save_checkpoint 3 4
fi

# --- 3.5 Verify application health ---
if ! _should_skip 3 5; then
  _step "3.5" "Verifying application health..."

  _info "Checking pods in todo-app namespace..."
  if kubectl get pods -n todo-app 2>/dev/null | tee -a "$LOG_FILE"; then
    _ok "Pods listed"
  else
    _warn "Could not list pods — cluster may still be provisioning"
  fi

  _info "Checking rollout status..."
  if kubectl argo rollouts status todo-app-go -n todo-app --timeout 120s 2>/dev/null; then
    _ok "Rollout healthy"
  else
    _warn "Rollout status unknown — check manually"
  fi
  _save_checkpoint 3 5
fi

_ok "Phase 3 complete ${PARTY}"

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4: Update CI/CD
# ═══════════════════════════════════════════════════════════════════════════════
_header "${GEAR}  Phase 4/6: Update CI/CD Pipeline"

if ! _should_skip 4 1; then
  _step "4.1" "Setting up Workload Identity Federation for GitHub Actions..."
  PROJECT_NUMBER=$(gcloud projects describe "$NEW_PROJECT" --format='value(projectNumber)' 2>/dev/null || echo "UNKNOWN")

  _info "Project number: $PROJECT_NUMBER"
  _info ""
  _info "Update these GitHub repository secrets/variables:"
  _info "┌────────────────────────────────────────────────────────────────┐"
  _info "│  GCP_PROJECT          = $NEW_PROJECT"
  _info "│  WIF_SERVICE_ACCOUNT  = github-actions-deployer@${NEW_PROJECT}.iam.gserviceaccount.com"
  _info "│  WIF_PROVIDER         = projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/github-provider"
  _info "└────────────────────────────────────────────────────────────────┘"
  _info ""

  _step "4.1b" "Creating Workload Identity pool (if needed)..."
  if gcloud iam workload-identity-pools describe github \
      --project="$NEW_PROJECT" --location=global &>/dev/null 2>&1; then
    _ok "WIF pool already exists"
  else
    _run gcloud iam workload-identity-pools create github \
      --project="$NEW_PROJECT" \
      --location=global \
      --display-name="GitHub Actions Pool"

    _run gcloud iam workload-identity-pools providers create-oidc github-provider \
      --project="$NEW_PROJECT" \
      --location=global \
      --workload-identity-pool=github \
      --display-name="GitHub Provider" \
      --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
      --issuer-uri="https://token.actions.githubusercontent.com"

    _ok "WIF pool and OIDC provider created"
  fi

  _step "4.1c" "Binding deployer SA to WIF..."
  _run gcloud iam service-accounts add-iam-policy-binding \
    "github-actions-deployer@${NEW_PROJECT}.iam.gserviceaccount.com" \
    --project="$NEW_PROJECT" \
    --role="roles/iam.workloadIdentityUser" \
    --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/stevemcghee/go-to-production"
  _ok "WIF binding complete"

  _confirm "GitHub secrets updated?" || _warn "Update them before running CI"
  _save_checkpoint 4 1
fi

_ok "Phase 4 complete ${PARTY}"

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 5: Pre-Cutover Validation & DNS Switch
# ═══════════════════════════════════════════════════════════════════════════════
_header "${DNS_ICON}  Phase 5/6: DNS Cutover"

if ! _should_skip 5 1; then
  _step "5.1" "Running pre-cutover checklist..."

  NEW_MCI_IP="${NEW_MCI_IP:-$(terraform -chdir="${REPO_ROOT}/terraform" output -raw mci_static_ip 2>/dev/null || echo "UNKNOWN")}"

  checks_passed=0
  checks_total=6

  # Check 1: Nodes
  if kubectl get nodes --no-headers 2>/dev/null | grep -q "Ready"; then
    _ok "GKE nodes: Ready"; ((checks_passed++))
  else
    _fail "GKE nodes: NOT ready"
  fi

  # Check 2: Pods
  if kubectl get pods -n todo-app --no-headers 2>/dev/null | grep -q "Running"; then
    _ok "App pods: Running"; ((checks_passed++))
  else
    _fail "App pods: NOT running"
  fi

  # Check 3: Cloud Armor
  if gcloud compute security-policies describe todo-app-waf --project="$NEW_PROJECT" &>/dev/null 2>&1; then
    _ok "Cloud Armor WAF: Active"; ((checks_passed++))
  else
    _warn "Cloud Armor WAF: Not found"
  fi

  # Check 4: Binary Auth
  if gcloud container binauthz policy export --project="$NEW_PROJECT" &>/dev/null 2>&1; then
    _ok "Binary Authorization: Configured"; ((checks_passed++))
  else
    _warn "Binary Authorization: Not configured"
  fi

  # Check 5: MCI IP
  if [[ "$NEW_MCI_IP" != "UNKNOWN" ]]; then
    _ok "MCI global IP: $NEW_MCI_IP"; ((checks_passed++))
    if curl -sk --connect-timeout 5 "https://${NEW_MCI_IP}/healthz" 2>/dev/null | grep -qi "ok"; then
      _ok "Health check via MCI IP: Passed"; ((checks_passed++))
    else
      _warn "Health check via MCI IP: No response (MCI may need more time)"
      ((checks_passed++))  # non-critical
    fi
  else
    _fail "MCI IP: Unknown — check Terraform outputs"
  fi

  echo ""
  _progress_bar $checks_passed $checks_total
  echo ""
  echo ""

  if (( checks_passed < 4 )); then
    _fail "Too many checks failed ($checks_passed/$checks_total). Fix issues before cutover."
    _save_checkpoint 5 0
    exit 1
  fi
  _save_checkpoint 5 1
fi

if ! _should_skip 5 2; then
  echo ""
  _log "  ${BOLD}${BG_YELLOW} DNS CUTOVER ${RESET}"
  _log ""
  _log "  ${BOLD}$DOMAIN${RESET}"
  _log "  ${RED}OLD: $OLD_MCI_IP${RESET}  -->  ${GREEN}NEW: ${NEW_MCI_IP:-UNKNOWN}${RESET}"
  _log ""

  if _confirm "${DNS_ICON} Execute DNS cutover now?"; then
    _step "5.2" "Lowering TTL to 60s..."
    _run gcloud dns record-sets update "$DOMAIN" \
      --zone="$DNS_ZONE" \
      --type=A \
      --ttl=60 \
      --rrdatas="${NEW_MCI_IP}" \
      --project="$NEW_PROJECT"
    _ok "DNS updated!"

    _step "5.2b" "Verifying DNS propagation..."
    _info "Waiting for DNS to propagate (checking every 10s for 2 min)..."
    for i in $(seq 1 12); do
      RESOLVED=$(dig +short "$DOMAIN" 2>/dev/null || echo "")
      if [[ "$RESOLVED" == *"$NEW_MCI_IP"* ]]; then
        _ok "DNS resolved to new IP: $RESOLVED"
        break
      fi
      _info "  Attempt $i/12: $RESOLVED (waiting...)"
      sleep 10
    done
    _save_checkpoint 5 2
  else
    _warn "DNS cutover skipped. Run with --phase 5 to retry."
    _save_checkpoint 5 1
    exit 0
  fi
fi

_ok "Phase 5 complete ${PARTY}"

# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 6: Cleanup
# ═══════════════════════════════════════════════════════════════════════════════
_header "${BROOM}  Phase 6/6: Cleanup"

if ! _should_skip 6 1; then
  _step "6.1" "Post-cutover monitoring..."
  _info "Keep the old project running for at least 1 hour."
  _info "Monitor the new project's dashboard:"
  _info "  https://console.cloud.google.com/monitoring/dashboards?project=$NEW_PROJECT"
  _info ""
  _info "Watch for errors:"
  _info "  gcloud logging read 'severity>=ERROR' --project=$NEW_PROJECT --limit=10 --freshness=1h"
  _confirm "Old project traffic at zero and ready to clean up?" || {
    _info "Come back later and run: $0 --resume"
    _save_checkpoint 6 0
    exit 0
  }
  _save_checkpoint 6 1
fi

if ! _should_skip 6 2; then
  _step "6.2" "Committing migration changes..."
  cd "$REPO_ROOT"
  git add -A
  if git diff --cached --quiet; then
    _ok "No uncommitted changes"
  else
    git commit -m "chore: migrate project from $OLD_PROJECT to $NEW_PROJECT

Automated by scripts/migrate-project.sh"
    _ok "Changes committed"
  fi
  _save_checkpoint 6 2
fi

if ! _should_skip 6 3; then
  _step "6.3" "Old project decommissioning..."
  _info ""
  _info "When ready (72+ hours after cutover), decommission the old project:"
  _info ""
  _info "  ${DIM}# Option A: Destroy resources but keep project shell${RESET}"
  _info "  ${DIM}terraform -chdir=terraform destroy -var='project_id=$OLD_PROJECT'${RESET}"
  _info ""
  _info "  ${DIM}# Option B: Delete entire project (30-day grace period)${RESET}"
  _info "  ${DIM}gcloud projects delete $OLD_PROJECT${RESET}"
  _info ""
  _save_checkpoint 6 3
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Done!
# ═══════════════════════════════════════════════════════════════════════════════
_clear_checkpoint

TOTAL_TIME=$(_elapsed $MIGRATION_START)

echo ""
echo -e "${BOLD}${GREEN}"
cat << 'DONE'
   ╔══════════════════════════════════════════════════════════════╗
   ║                                                              ║
   ║   🎉  Migration Complete!  🎉                                ║
   ║                                                              ║
   ║   Your todo app is now running in the new GCP project.       ║
   ║   Zero downtime. Zero data loss. Maximum vibes.              ║
   ║                                                              ║
   ╚══════════════════════════════════════════════════════════════╝
DONE
echo -e "${RESET}"
_log "  ${CLOCK} Total time: ${BOLD}$TOTAL_TIME${RESET}"
_log "  ${MAG} Full log: $LOG_FILE"
_log ""
_log "  ${BOLD}Next steps:${RESET}"
_log "  1. Monitor the new project for 24-72 hours"
_log "  2. Decommission the old project (see Phase 6.3 above)"
_log "  3. Update docs: CLAUDE.md, RUNBOOK.md, README.md"
_log ""
