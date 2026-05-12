# Zero-Downtime GCP Project Migration Plan

## Overview

This document describes a zero-downtime migration of the entire go-to-production
stack from the current GCP project (`${OLD_PROJECT}`) to a new GCP
project. The approach uses a **parallel-deploy + DNS-cutover** strategy: the
complete infrastructure is stood up in the new project while the old project
continues serving traffic, then DNS is atomically switched once the new stack
is healthy.

**Estimated migration window:** 4–6 hours (infrastructure provisioning) +
minutes (DNS cutover). Zero user-facing downtime.

**Cost impact:** Both projects run simultaneously during the transition
(~$34/day × 2 = ~$68/day). Old project can be torn down within 24–72 hours
after successful cutover.

---

## Prerequisites

Before starting, ensure:

- [ ] New GCP project created with billing enabled
- [ ] `gcloud` CLI authenticated with Owner/Editor on both old and new projects
- [ ] Terraform >= 1.5 installed locally
- [ ] `kubectl`, `helm`, `kustomize`, `cosign` installed
- [ ] DNS control over `${DOMAIN_NAME}` (or whatever domain is in use)
- [ ] GitHub repository admin access (for secrets/OIDC updates)
- [ ] Current database backup verified (run a restore test first)
- [ ] Record the new project ID — referred to as `${NEW_PROJECT}` below

---

## Architecture Inventory

Everything that must be recreated in the new project:

| Layer | Resources | Source of Truth |
|-------|-----------|-----------------|
| APIs | 19 GCP APIs enabled | `terraform/main.tf` |
| Network | VPC, 2 subnets (us-central1, us-east1) | `terraform/main.tf` |
| Compute | 2 GKE clusters (primary + secondary) | `terraform/main.tf` |
| Database | Cloud SQL primary (HA) + read replica | `terraform/main.tf` |
| Registry | Artifact Registry (`todo-app-go`) | `terraform/main.tf` |
| IAM | 3 service accounts + Workload Identity | `terraform/iam.tf` |
| Secrets | 2 Secret Manager secrets | `terraform/secrets.tf` |
| Security | Cloud Armor WAF policy | `terraform/security_policy.tf` |
| Security | Binary Authorization + Cosign attestor | `terraform/binary-authorization.tf` |
| Policy | OPA Gatekeeper (both clusters) | `terraform/gatekeeper.tf` |
| GitOps | ArgoCD (both clusters) + Argo Rollouts | `terraform/argocd.tf`, `rollouts.tf` |
| Networking | MCI, global IP, fleet memberships | `terraform/mci.tf` |
| Backups | GKE Backup plan (daily) | `terraform/backup.tf` |
| Monitoring | Dashboard, SLOs, alert policies | `terraform/dashboard.tf`, `slos.tf`, `alerts.tf` |

---

## Phase 1: Prepare the New Project (Day 1)

### 1.0 Set Environment Variables

First, set these environment variables in your terminal to make the following commands copy-pasteable:

```bash
export OLD_PROJECT="your-old-project-id"
export NEW_PROJECT="your-new-project-id"
export BILLING_ACCOUNT_ID="your-billing-account-id"
export DOMAIN_NAME="todo.smig.dev"
export DNS_ZONE="smig-dev-zone"
export OLD_MCI_IP="34.160.71.244"
```

### 1.1 Create the GCP project and enable billing

```bash
gcloud projects create ${NEW_PROJECT} --name="Todo App Production"
gcloud billing projects link ${NEW_PROJECT} --billing-account=${BILLING_ACCOUNT_ID}
```

### 1.2 Create the Terraform state bucket

```bash
gsutil mb -p ${NEW_PROJECT} -l us-central1 gs://tf-state-${NEW_PROJECT}
gsutil versioning set on gs://tf-state-${NEW_PROJECT}
```

### 1.3 Create a migration branch

```bash
git checkout -b project-migration main
```

### 1.4 Update Terraform backend

Edit `terraform/main.tf`:

```hcl
terraform {
  backend "gcs" {
    bucket = "tf-state-${NEW_PROJECT}"    # was: tf-state-${OLD_PROJECT}
    prefix = "terraform/state"
  }
}
```

### 1.5 Create new `terraform.tfvars`

```hcl
project_id  = "${NEW_PROJECT}"
db_password = "GENERATE_A_NEW_SECURE_PASSWORD"
alert_email = "your-alert-email@example.com"
```

### 1.6 Initialize and apply Terraform

```bash
cd terraform
terraform init -reconfigure
terraform plan -out=migration.tfplan
terraform apply migration.tfplan
```

This provisions:
- VPC + subnets in both regions
- GKE clusters (primary + secondary) with node pools
- Cloud SQL primary (HA) + read replica
- Artifact Registry
- All IAM service accounts and bindings
- Secret Manager secrets
- Cloud Armor WAF
- Binary Authorization policy + attestor
- MCI fleet memberships + global IP
- GKE Backup plan
- Monitoring dashboard, SLOs, alert policies
- ArgoCD + Argo Rollouts on both clusters

**Expected duration:** 20–40 minutes (Cloud SQL and GKE are the bottlenecks).

Record the new global IP from Terraform output and export it:
```bash
export NEW_MCI_IP=$(terraform output -raw mci_static_ip)
# Verify it: echo $NEW_MCI_IP
```

---

## Phase 2: Migrate Data (Day 1, after Phase 1)

### 2.1 Export database from old project

```bash
# Create an export in the old project
gcloud sql export sql todo-app-db-instance \
  gs://tf-state-${OLD_PROJECT}/db-export/migration.sql \
  --database=todoapp_db \
  --project=${OLD_PROJECT}
```

### 2.2 Import into new project

```bash
# Copy the export to the new project's bucket (or use cross-project access)
gsutil cp gs://tf-state-${OLD_PROJECT}/db-export/migration.sql \
         gs://tf-state-${NEW_PROJECT}/db-import/migration.sql

# Grant the new Cloud SQL instance access to the bucket
SA=$(gcloud sql instances describe todo-app-db-instance \
  --project=${NEW_PROJECT} --format='value(serviceAccountEmailAddress)')
gsutil iam ch serviceAccount:${SA}:objectViewer gs://tf-state-${NEW_PROJECT}

# Import
gcloud sql import sql todo-app-db-instance \
  gs://tf-state-${NEW_PROJECT}/db-import/migration.sql \
  --database=todoapp_db \
  --project=${NEW_PROJECT}
```

### 2.3 Create the IAM database user

Run the IAM user creation job against the new cluster:

```bash
# Get credentials for the new primary cluster
gcloud container clusters get-credentials todo-app-cluster \
  --region=us-central1 --project=${NEW_PROJECT}

# Apply the IAM user creation job
kubectl apply -f k8s/base/create-iam-user-job.yaml
kubectl wait --for=condition=complete job/create-iam-user -n todo-app --timeout=120s
```

### 2.4 Verify data integrity

```bash
# Port-forward Cloud SQL proxy and run a quick count
kubectl run pg-verify --rm -it --restart=Never \
  --image=postgres:14 -- psql "host=127.0.0.1 dbname=todoapp_db user=todoappuser" \
  -c "SELECT count(*) FROM todos;"
```

Compare the count against the old project. For small datasets, diff the full
table contents.

---

## Phase 3: Build & Deploy the Application (Day 1, after Phase 2)

### 3.1 Update all hardcoded project references

The project ID `${OLD_PROJECT}` appears in these files. Every
occurrence must be updated to `${NEW_PROJECT}`:

| File | What to Change |
|------|----------------|
| `main.go:44` | Fallback `projectID` constant |
| `k8s/base/kustomization.yaml:26` | Container image registry path |
| `k8s/base/serviceaccount.yaml:7` | Workload Identity annotation |
| `k8s/base/create-iam-user-job.yaml:20-23` | IAM user + Cloud SQL Proxy instance |
| `k8s/base/db-init-job.yaml:35-36,70` | IAM grants + Cloud SQL Proxy instance |
| `k8s/base/rollouts/todo-app-rollout.yaml:49-50` | Cloud SQL Proxy instances (primary + replica) |
| `skaffold.yaml:11` | Cloud Build project ID |
| `clouddeploy.yaml:28,35` | Cloud Deploy cluster + service account |
| `binauthz-policy.yaml:10,21,26,31,32` | Attestor + image policy references |
| `terraform/main.tf:18` | State bucket name (already done in Phase 1) |
| `terraform/import_state.sh` | Script `PROJECT_ID` variable |

A sed one-liner for the bulk of it:

```bash
grep -rl "${OLD_PROJECT}" --include='*.go' --include='*.yaml' --include='*.sh' . \
  | xargs sed -i "s/${OLD_PROJECT}/${NEW_PROJECT}/g"
```

**Verify no references remain:**

```bash
grep -r "${OLD_PROJECT}" . --include='*.go' --include='*.yaml' --include='*.tf' --include='*.sh'
# Should return zero results (except possibly docs, which are fine)
```

### 3.2 Build and push the container image

```bash
# Authenticate to the new Artifact Registry
gcloud auth configure-docker us-central1-docker.pkg.dev --project=${NEW_PROJECT}

# Build
docker build -t us-central1-docker.pkg.dev/${NEW_PROJECT}/todo-app-go/todo-app-go:migration .

# Push
docker push us-central1-docker.pkg.dev/${NEW_PROJECT}/todo-app-go/todo-app-go:migration

# Sign with Cosign (for Binary Authorization)
cosign sign --yes us-central1-docker.pkg.dev/${NEW_PROJECT}/todo-app-go/todo-app-go:migration
```

### 3.3 Update Kustomize image tag

Edit `k8s/base/kustomization.yaml` to reference the new image digest:

```yaml
images:
  - name: us-central1-docker.pkg.dev/${NEW_PROJECT}/todo-app-go/todo-app-go
    digest: sha256:<NEW_DIGEST>
```

### 3.4 Deploy to new clusters via ArgoCD

ArgoCD in the new project needs to point at the repository:

```bash
# Port-forward ArgoCD in the new cluster
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Login
argocd login localhost:8080 --insecure \
  --username admin \
  --password $(kubectl -n argocd get secret argocd-initial-admin-secret \
    -o jsonpath="{.data.password}" | base64 -d)

# Create the application (or let Terraform's ArgoCD config handle it)
argocd app create todo-app \
  --repo https://github.com/stevemcghee/go-to-production.git \
  --revision project-migration \
  --path k8s/ \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace todo-app \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

### 3.5 Verify the application is healthy

```bash
# Check rollout status
kubectl argo rollouts status todo-app-go -n todo-app

# Check pods are running
kubectl get pods -n todo-app

# Hit the health endpoint
kubectl port-forward svc/todo-app-go-service -n todo-app 8080:80
curl http://localhost:8080/healthz
# Expected: {"status":"ok","db":"connected",...}

# Verify data is served
curl http://localhost:8080/todos
```

---

## Phase 4: Update CI/CD (Day 1, after Phase 3)

### 4.1 Update GitHub Actions secrets/variables

In the GitHub repository settings, update:

| Secret/Variable | Old Value | New Value |
|-----------------|-----------|-----------|
| `GCP_PROJECT` (var) | `${OLD_PROJECT}` | `${NEW_PROJECT}` |
| `GCP_SA_KEY` or OIDC | Old project SA | New `github-actions-deployer` SA |
| `WIF_PROVIDER` | Old Workload Identity pool | New pool (if using OIDC) |
| `WIF_SERVICE_ACCOUNT` | Old SA email | New SA email |

### 4.2 Update GitHub Actions OIDC (if applicable)

If using Workload Identity Federation for keyless auth, you will first need the new project's number:

```bash
export PROJECT_NUMBER=$(gcloud projects describe ${NEW_PROJECT} --format='value(projectNumber)')

# In the new project, create the WIF pool and provider
gcloud iam workload-identity-pools create "github" \
  --project=${NEW_PROJECT} \
  --location="global" \
  --display-name="GitHub Actions Pool"

gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project=${NEW_PROJECT} \
  --location="global" \
  --workload-identity-pool="github" \
  --display-name="GitHub Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# Bind the deployer SA
gcloud iam service-accounts add-iam-policy-binding \
  github-actions-deployer@${NEW_PROJECT}.iam.gserviceaccount.com \
  --project=${NEW_PROJECT} \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/stevemcghee/go-to-production"
```

### 4.3 Test CI pipeline

Push a no-op commit to the migration branch and verify the full pipeline:
build → test → push → sign → ArgoCD sync.

---

## Phase 5: DNS Cutover (Day 2, maintenance window)

This is the only step that affects user traffic. It takes seconds to execute
and minutes to propagate.

### 5.1 Pre-cutover validation checklist

- [ ] New clusters healthy: `kubectl get nodes` on both clusters
- [ ] Application pods running and passing health checks on both clusters
- [ ] Database contains correct data (count matches old project)
- [ ] Read replica replication working (lag < 10s)
- [ ] Cloud Armor WAF policy active
- [ ] Binary Authorization enforcing signed images
- [ ] SLO monitoring dashboard showing data
- [ ] Alert policies firing test alerts correctly
- [ ] MCI global IP responding: `curl -k https://${NEW_MCI_IP}/healthz`
- [ ] ArgoCD synced and healthy

### 5.2 Execute DNS cutover

Update the A record for `${DOMAIN_NAME}`:

```
Old: ${DOMAIN_NAME} → ${OLD_MCI_IP}  (old project MCI IP)
New: ${DOMAIN_NAME} → ${NEW_MCI_IP}     (new project MCI IP)
```

Set a low TTL (60s) on the record before cutover to speed propagation.

```bash
# If using Cloud DNS:
gcloud dns record-sets update ${DOMAIN_NAME} \
  --zone=${DNS_ZONE} \
  --type=A \
  --ttl=60 \
  --rrdatas=${NEW_MCI_IP}

# If using an external registrar: update through their UI/API
```

### 5.3 Monitor the cutover

```bash
# Watch DNS propagation
watch -n5 dig +short ${DOMAIN_NAME}

# Monitor error rate in new project
# Open the Cloud Monitoring dashboard:
# https://console.cloud.google.com/monitoring/dashboards?project=${NEW_PROJECT}

# Check SLO burn rate
gcloud monitoring slos list --project=${NEW_PROJECT}
```

### 5.4 Keep old project running

Leave the old project serving traffic for at least 1 hour after DNS cutover.
Clients with cached DNS will still hit the old project. Since the old database
is now stale, consider two options:

**Option A (simple):** Accept that writes during propagation go to the old DB
and are lost. Suitable if traffic is very low or data is non-critical.

**Option B (zero data loss):** Before DNS cutover, put the old app in
read-only mode (return 503 on POST/PUT/DELETE). Then cutover DNS. Users see
a brief read-only period (~minutes) until DNS propagates.

**Option C (advanced):** Run a final database diff/sync after DNS has fully
propagated (all traffic hitting new project). Export any new rows from old DB,
import into new DB. This captures writes that arrived at the old project
during DNS propagation.

---

## Phase 6: Cleanup (Day 3+)

### 6.1 Verify no traffic to old project

Check Cloud Monitoring in the old project. If request rate is zero for 2+
hours, proceed.

### 6.2 Final data reconciliation

If using Option C above, run the final sync now:

```bash
# Export any rows created after the initial migration export
gcloud sql export sql todo-app-db-instance \
  gs://tf-state-${OLD_PROJECT}/db-export/final-delta.sql \
  --database=todoapp_db \
  --project=${OLD_PROJECT}

# Review and selectively import into new project
```

### 6.3 Merge the migration branch

```bash
git checkout main
git merge project-migration
git tag milestone-project-migration
git push origin main --tags
```

### 6.4 Decommission old project

**Wait at least 72 hours** after DNS cutover before deleting:

```bash
# Option 1: Shut down resources but keep project (recommended for 30 days)
cd terraform
# Point backend back to old bucket temporarily
terraform destroy -var="project_id=${OLD_PROJECT}"

# Option 2: Delete entire project (irreversible after 30-day grace period)
gcloud projects delete ${OLD_PROJECT}
```

### 6.5 Update documentation

- [ ] Update `CLAUDE.md` with new project ID
- [ ] Update `docs/RUNBOOK.md` with new project references
- [ ] Update `README.md` project references
- [ ] Update any dashboard URLs in documentation

---

## Rollback Plan

If problems are discovered after DNS cutover:

### Immediate rollback (< 1 hour after cutover)

1. Revert DNS to old project's MCI IP:
   ```bash
   gcloud dns record-sets update ${DOMAIN_NAME} \
     --zone=${DNS_ZONE} --type=A --ttl=60 \
     --rrdatas=${OLD_MCI_IP}
   ```
2. Old project is still running; traffic resumes there within minutes.
3. Investigate and fix issues in new project.
4. Retry cutover.

### Late rollback (> 1 hour, old project may have stale data)

1. Revert DNS (same as above).
2. Export any new data from new project's DB.
3. Import delta into old project's DB.
4. Verify old project is fully operational.
5. Root-cause the issue before attempting cutover again.

---

## Risk Register

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| DNS propagation delay | Users hit old project for minutes | High | Set TTL=60 before cutover; keep old project running |
| Data written to old project during cutover | Lost writes | Medium | Option B (read-only mode) or Option C (delta sync) |
| Terraform apply failure in new project | Delays migration | Medium | Test with `terraform plan` first; fix errors before proceeding |
| Cloud SQL import failure | No data in new project | Low | Verify export, test import to a scratch instance first |
| Binary Authorization blocks new image | App won't deploy | Low | Pre-sign image, verify attestor is correctly configured |
| GitHub Actions OIDC misconfigured | CI/CD broken | Medium | Test pipeline on migration branch before DNS cutover |
| ArgoCD can't reach secondary cluster | East cluster out of sync | Low | Verify cluster registration, test sync before cutover |
| MCI global IP not healthy | No ingress | Medium | `curl` test MCI IP directly before switching DNS |
| Cost overrun from parallel projects | Double spend | High | Tear down old project within 72 hours |

---

## Timeline Summary

| Time | Phase | Duration | User Impact |
|------|-------|----------|-------------|
| T+0h | Phase 1: Terraform apply (new project) | 30–45 min | None |
| T+1h | Phase 2: Database migration | 15–30 min | None |
| T+2h | Phase 3: Build, deploy, verify app | 30–60 min | None |
| T+3h | Phase 4: Update CI/CD, test pipeline | 30 min | None |
| T+4h | Phase 5: Pre-cutover validation | 30 min | None |
| T+4.5h | Phase 5: DNS cutover | 5 min | **Brief read-only (Option B)** or none |
| T+5h | Monitor | 1–2 hours | None |
| T+72h | Phase 6: Decommission old project | 30 min | None |

**Total user-facing downtime: Zero** (with Option A or B).
