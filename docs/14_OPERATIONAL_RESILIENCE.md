# Milestone 14: Operational Resilience

This milestone closes the six highest-priority open risks from the risk matrix in
`STRATEGY_AND_RISKS.md`. Each deliverable maps directly to a named risk.

## 1. Checkout this Milestone

```bash
git checkout tags/milestone-14-operational-resilience
```

## 2. Risks Addressed

| # | Risk | Score | Deliverable |
|---|------|-------|-------------|
| 1 | Quota Exhaustion | **6** | Quota monitoring & alerts |
| 2 | Sensitive Data Leakage | **6** | Structured log redaction |
| 3 | Insider Threat | **4** | Audit log sink + IAM hardening |
| 4 | Backup Restore Failure | **4** | Automated restore drill |
| 5 | Ransomware / Corruption | **3** | GCS bucket lock & retention |
| 6 | Billing Spike | **3** | Budget alerts + spending cap |

## 3. What to Implement

### 3.1 Structured Logging with PII Redaction (Sensitive Data Leakage — Score 6)

**Problem:** Application logs may contain user-submitted data (todo text, request
bodies) that could include PII. No redaction or classification exists today.

**Implementation:**

1. **Add a `sanitizeLog` helper in `internal/app/app.go`:**
   - Accept a string; apply regex-based redaction for common PII patterns
     (email addresses, credit card numbers, SSNs).
   - Replace matches with `[REDACTED]`.
   - Use Go's `log/slog` structured logging (already in use) and pass all
     user-supplied values through the sanitizer before logging.

2. **Create a logging policy doc (`docs/LOGGING_POLICY.md`):**
   - Define what is safe to log (request path, method, status, latency, trace ID).
   - Define what must never be logged (request/response bodies containing user
     data, authorization headers, cookie values).
   - Reference this policy from the runbook.

3. **Add a Gatekeeper policy (optional):**
   - `k8s/base/policies/template-no-env-secrets.yaml` — warn if a Pod spec
     contains `env` entries with names like `PASSWORD`, `SECRET`, `TOKEN` that
     are not sourced from a Secret reference.

**Files changed:**
- `internal/app/app.go` — new `sanitizeLog()`, update log calls in handlers.
- `docs/LOGGING_POLICY.md` — new file.
- `k8s/base/policies/` — optional new template + constraint.

### 3.2 Quota Monitoring & Alerts (Quota Exhaustion — Score 6)

**Problem:** No alerting exists for GCP resource quota consumption. Running out of
CPU, IP addresses, or Cloud SQL connections would cause outages with no warning.

**Implementation:**

1. **Add alert policies in `terraform/alerts.tf`:**
   ```hcl
   # Alert when any quota exceeds 80% utilization
   resource "google_monitoring_alert_policy" "quota_usage" {
     display_name = "GCP Quota Usage > 80%"
     combiner     = "OR"
     conditions {
       display_name = "Quota usage high"
       condition_threshold {
         filter          = "metric.type=\"serviceruntime.googleapis.com/quota/allocation/usage\" AND resource.type=\"consumer_quota\""
         comparison      = "COMPARISON_GT"
         threshold_value = 0.8
         duration        = "0s"
         aggregations {
           alignment_period   = "300s"
           per_series_aligner = "ALIGN_MEAN"
         }
       }
     }
     notification_channels = [google_monitoring_notification_channel.email.id]
   }
   ```

2. **Add a dashboard widget in `terraform/dashboard.tf`:**
   - Quota usage gauges for Compute Engine CPUs, in-use IP addresses, and
     Cloud SQL connections.

**Files changed:**
- `terraform/alerts.tf` — new alert policy.
- `terraform/dashboard.tf` — new dashboard widget.

### 3.3 Budget Alerts & Spending Cap (Billing Spike — Score 3)

**Problem:** No budget alerts or anomaly detection. A misconfiguration (e.g.,
auto-scaler runaway) could cause an unexpected billing spike.

**Implementation:**

1. **Create `terraform/budget.tf`:**
   ```hcl
   resource "google_billing_budget" "monthly_budget" {
     billing_account = var.billing_account_id
     display_name    = "go-to-production Monthly Budget"

     budget_filter {
       projects = ["projects/${var.project_id}"]
     }

     amount {
       specified_amount {
         currency_code = "USD"
         units         = "600"  # ~$20/day * 30 days
       }
     }

     threshold_rules {
       threshold_percent = 0.5   # 50% — informational
       spend_basis       = "CURRENT_SPEND"
     }
     threshold_rules {
       threshold_percent = 0.8   # 80% — warning
       spend_basis       = "CURRENT_SPEND"
     }
     threshold_rules {
       threshold_percent = 1.0   # 100% — critical
       spend_basis       = "CURRENT_SPEND"
     }
   }
   ```

2. **Add `billing_account_id` to `terraform/variables.tf`.**

**Files changed:**
- `terraform/budget.tf` — new file.
- `terraform/variables.tf` — new variable.

### 3.4 Automated Backup Restore Drill (Backup Restore Failure — Score 4)

**Problem:** Backups exist (Cloud SQL PITR + GKE Backup Plan) but have never been
tested with an automated drill. A restore failure during a real incident would be
catastrophic.

**Implementation:**

1. **Create `scripts/backup-restore-drill.sh`:**
   - Clone the Cloud SQL instance from the latest PITR timestamp to a
     temporary instance (`todo-app-db-drill-YYYYMMDD`).
   - Run a connectivity check and a `SELECT count(*) FROM todos` query.
   - Delete the temporary instance.
   - Output PASS/FAIL and log to Cloud Logging with a structured label
     (`drill=backup-restore`).

2. **Create `k8s/base/backup-drill-cronjob.yaml`:**
   - Monthly CronJob (1st of each month at 03:00 UTC).
   - Uses a lightweight image with `gcloud` and `psql`.
   - Runs the drill script.
   - Alert on failure via the existing notification channel.

3. **Add a runbook entry** in `docs/RUNBOOK.md` for the drill procedure and
   what to do if the drill fails.

**Files changed:**
- `scripts/backup-restore-drill.sh` — new file.
- `k8s/base/backup-drill-cronjob.yaml` — new file.
- `k8s/base/kustomization.yaml` — add the CronJob reference.
- `docs/RUNBOOK.md` — new section.

### 3.5 GCS Bucket Lock & Retention (Ransomware / Corruption — Score 3)

**Problem:** Backup data in GCS has no retention policy. A compromised service
account or insider could delete backups.

**Implementation:**

1. **Update `terraform/backup.tf`:**
   - Add a `retention_policy` block to the GCS backup bucket with a 30-day
     minimum retention period.
   - Enable `default_event_based_hold` so objects cannot be deleted before the
     retention period expires.

2. **Enable Object Versioning** on the Terraform state bucket (defense in depth).

**Files changed:**
- `terraform/backup.tf` — retention policy.

### 3.6 Audit Log Sink & IAM Hardening (Insider Threat — Score 4)

**Problem:** No centralized audit trail for admin actions. No just-in-time (JIT)
access controls.

**Implementation:**

1. **Create `terraform/audit.tf`:**
   - Enable Data Access audit logs for Cloud SQL and GKE.
   - Create a log sink exporting admin activity to a dedicated BigQuery dataset
     (for long-term retention and querying).
   - Create an alert for sensitive IAM actions:
     `protoPayload.methodName="SetIamPolicy"`.

2. **Document JIT access pattern** in `docs/RUNBOOK.md`:
   - Recommend using IAM Conditions with time-bound grants.
   - Reference GCP's PAM (Privileged Access Manager) for production use.

**Files changed:**
- `terraform/audit.tf` — new file.
- `docs/RUNBOOK.md` — JIT access section.

## 4. Verification Checklist

- [ ] `go test -v ./...` passes with redaction tests.
- [ ] `terraform plan` shows new alert policies, budget, audit sink, retention.
- [ ] Backup drill CronJob runs successfully (manual trigger: `kubectl create job --from=cronjob/backup-restore-drill drill-test -n todo-app`).
- [ ] Risk matrix updated: all six risks flipped to ✅.

## 5. Pitfalls & Considerations

- **Quota alerts** depend on the `serviceruntime.googleapis.com` API being enabled.
- **Budget alerts** require the Cloud Billing API and a billing account ID.
- **Backup drill** creates a temporary Cloud SQL instance — ensure quotas allow it
  and the instance is cleaned up on failure (add a trap in the script).
- **Audit log sinks** can generate significant BigQuery storage costs if Data Access
  logs are very verbose. Start with Admin Activity only, then expand.

## 6. Alternatives Considered

- **Log redaction via Fluentd / Cloud Logging exclusion filters:** Works at the
  infrastructure layer but doesn't prevent PII from being emitted in the first
  place. We chose application-level redaction for defense-in-depth.
- **Third-party budget tools (e.g., Infracost):** Useful for Terraform plan cost
  estimation but doesn't replace runtime billing alerts.
- **Vault for JIT secrets:** Considered but adds significant operational complexity.
  GCP PAM is sufficient for this project's scale.
