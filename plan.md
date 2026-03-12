# Milestone 14: Operational Resilience — Implementation Plan

Closes six open risks from `docs/STRATEGY_AND_RISKS.md`. Ordered by risk score (highest first).

---

## Step 1: Structured Logging + PII Redaction (Sensitive Data Leakage — Score 6)

**Files to change:**
- `internal/app/app.go` — add `sanitizeLog()` function + update log call sites
- `main_test.go` — add unit tests for the sanitizer

**What to do:**
1. Add a `sanitizeLog(s string) string` function using `regexp` to redact:
   - Email addresses → `[REDACTED-EMAIL]`
   - Credit card numbers (16-digit patterns) → `[REDACTED-CC]`
   - SSN patterns (XXX-XX-XXXX) → `[REDACTED-SSN]`
2. Update the three log lines in handlers that log user-submitted data:
   - Line 575: `slog.Info("Decoded todo", "task", t.Task)` → pass through `sanitizeLog`
   - Line 582: `slog.Error("Failed to insert todo", ...)` → sanitize `t.Task`
   - Line 593: `slog.Info("Successfully added todo", ...)` → sanitize `t.Task`
3. Add unit tests: verify known PII patterns are redacted, verify safe strings pass through unchanged.

**Not doing:** Logging policy doc (`docs/LOGGING_POLICY.md`) and Gatekeeper policy — these are optional per the milestone doc and add no code value.

---

## Step 2: Quota Monitoring Alerts (Quota Exhaustion — Score 6)

**Files to change:**
- `terraform/alerts.tf` — add quota alert policy

**What to do:**
1. Add `google_monitoring_alert_policy.quota_usage` — triggers when any GCP quota exceeds 80% utilization.
   - Filter: `metric.type="serviceruntime.googleapis.com/quota/allocation/usage"` with `resource.type="consumer_quota"`
   - Uses the existing `google_monitoring_notification_channel.email` channel.

**Not doing:** Dashboard widget for quota gauges — the alert is what matters operationally; dashboard is nice-to-have.

---

## Step 3: Budget Alerts + Billing Cap (Billing Spike — Score 3)

**Files to change:**
- `terraform/budget.tf` — new file
- `terraform/variables.tf` — add `billing_account_id` variable

**What to do:**
1. Create `budget.tf` with `google_billing_budget.monthly_budget`:
   - Amount: $600/month (~$20/day × 30)
   - Thresholds at 50%, 80%, 100% of current spend
   - Notification via existing email channel (using pubsub or monitoring channel as available)
2. Add `billing_account_id` variable to `variables.tf` (sensitive, no default).

---

## Step 4: Automated Backup Restore Drill (Backup Restore Failure — Score 4)

**Files to change:**
- `scripts/backup-restore-drill.sh` — new file
- `k8s/base/backup-drill-cronjob.yaml` — new file
- `k8s/base/kustomization.yaml` — add CronJob reference

**What to do:**
1. Create `scripts/backup-restore-drill.sh`:
   - Clone Cloud SQL primary via PITR to temp instance (`todo-app-db-drill-YYYYMMDD`)
   - Wait for instance to become RUNNABLE
   - Connect via Cloud SQL Proxy, run `SELECT count(*) FROM todos`
   - Compare row count against primary
   - Clean up temp instance (with `trap` for failure cleanup)
   - Log structured PASS/FAIL to stdout (picked up by Cloud Logging)
2. Create `k8s/base/backup-drill-cronjob.yaml`:
   - Schedule: `0 3 1 * *` (monthly, 1st day, 03:00 UTC)
   - Image: `google/cloud-sdk:alpine`
   - Mount the drill script or embed it inline
   - `restartPolicy: Never`, `backoffLimit: 1`
3. Add the CronJob to `k8s/base/kustomization.yaml` resources list.

---

## Step 5: GCS Bucket Lock + Retention (Ransomware / Corruption — Score 3)

**Files to change:**
- `terraform/backup.tf` — add GCS bucket with retention policy

**What to do:**
1. Add a `google_storage_bucket.backups` resource (or update existing if one exists):
   - 30-day `retention_policy` with `is_locked = false` (can lock later after validation)
   - Enable `versioning`
2. The existing GKE backup plan stays as-is; this adds defense for any GCS-stored backups.

---

## Step 6: Audit Log Sink + IAM Hardening (Insider Threat — Score 4)

**Files to change:**
- `terraform/audit.tf` — new file

**What to do:**
1. Create `terraform/audit.tf` with:
   - `google_project_iam_audit_config` — enable Data Access audit logs for `cloudsql.googleapis.com` and `container.googleapis.com`
   - `google_bigquery_dataset.audit_logs` — dataset for long-term log retention
   - `google_logging_project_sink.admin_activity` — exports admin activity logs to BigQuery
   - `google_bigquery_dataset_iam_member` — grant the sink's writer identity access
   - `google_monitoring_alert_policy.iam_changes` — alert on `SetIamPolicy` calls

---

## Step 7: Update Risk Matrix + Runbook

**Files to change:**
- `docs/STRATEGY_AND_RISKS.md` — flip all six risks from ❌ to ✅
- `docs/RUNBOOK.md` — promote planned procedures from draft to active

**What to do:**
1. In `STRATEGY_AND_RISKS.md`, update Status for each of the six risks to `✅ Milestone 14`.
2. In `RUNBOOK.md`, move the "Planned Operational Procedures" section (quota alert response, billing spike response, backup drill, audit review) into the active runbook.

---

## Step 8: Validate

- Run `go test -v ./...` — must pass (includes new redaction tests)
- Run `go vet ./...` — must pass
- Run `terraform fmt` and `terraform validate` in `terraform/` — must pass
- Commit, tag `milestone-14-operational-resilience`, push

---

## Files Summary

| Action | File |
|--------|------|
| Edit | `internal/app/app.go` |
| Edit | `main_test.go` |
| Edit | `terraform/alerts.tf` |
| Edit | `terraform/backup.tf` |
| Edit | `terraform/variables.tf` |
| Edit | `k8s/base/kustomization.yaml` |
| Edit | `docs/STRATEGY_AND_RISKS.md` |
| Edit | `docs/RUNBOOK.md` |
| Create | `terraform/budget.tf` |
| Create | `terraform/audit.tf` |
| Create | `scripts/backup-restore-drill.sh` |
| Create | `k8s/base/backup-drill-cronjob.yaml` |
