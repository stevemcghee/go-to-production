# Milestone 15: Advanced Observability

This milestone builds on the existing Prometheus metrics and Cloud Trace
integration to achieve full-stack observability, chaos engineering, and
automated incident response.

## 1. Checkout this Milestone

```bash
git checkout tags/milestone-15-advanced-observability
```

## 2. Goals

- **Trace ↔ Log Correlation:** Every log line includes a `trace_id` so you can
  jump from a log entry to its distributed trace in one click.
- **Business SLIs:** Custom metrics for domain-specific health (not just HTTP
  error rates).
- **Chaos Engineering:** Controlled fault injection to validate resilience in
  production-like conditions.
- **Incident Playbooks:** Codified response procedures that can be triggered
  automatically or referenced during incidents.

## 3. What to Implement

### 3.1 Trace ↔ Log Correlation

**Problem:** Logs and traces are separate systems. Debugging requires manually
correlating timestamps.

**Implementation:**

1. **Extract `trace_id` from the OpenTelemetry span context** in every HTTP
   handler and inject it into the `slog` structured logger:
   ```go
   span := trace.SpanFromContext(r.Context())
   traceID := span.SpanContext().TraceID().String()
   slog.InfoContext(r.Context(), "request handled",
       "trace_id", traceID,
       "path", r.URL.Path,
       "status", status,
   )
   ```

2. **Configure Cloud Logging** to recognize the `trace_id` field and auto-link
   to Cloud Trace. GCP expects the format:
   `projects/PROJECT_ID/traces/TRACE_ID`.

3. **Update `SecurityHeadersMiddleware`** to log the trace ID on every request
   (one log line per request with method, path, status, latency, trace_id).

**Files changed:**
- `internal/app/app.go` — middleware update, handler log updates.

### 3.2 Custom Business SLIs

**Problem:** Current SLIs are purely infrastructure-level (HTTP 5xx rate, latency).
They don't capture business-level degradation.

**Implementation:**

1. **Add Prometheus counters for business events:**
   - `todo_completion_rate` — ratio of todos marked complete vs. created.
   - `todo_stale_count` — gauge of todos older than 7 days and not completed.

2. **Create a Cloud Monitoring SLO** on the business metric (e.g., 90% of todos
   are completed within 7 days — a "freshness" SLI).

3. **Add a dashboard section** in `terraform/dashboard.tf` for business metrics.

**Files changed:**
- `internal/app/app.go` — new Prometheus metrics.
- `terraform/slos.tf` — new SLO definition.
- `terraform/dashboard.tf` — new widget.

### 3.3 Chaos Engineering with Chaos Mesh

**Problem:** Resilience features (circuit breaker, retry, failover) are tested in
unit/chaos tests with mocks but have not been validated in a real cluster.

**Implementation:**

1. **Install Chaos Mesh** via Helm in a dedicated `chaos-testing` namespace:
   - Add `terraform/chaos_mesh.tf` with a `helm_release` resource.
   - Whitelist Chaos Mesh images in `binauthz-policy.yaml`.

2. **Define experiments in `test/chaos/experiments/`:**
   - `pod-kill.yaml` — randomly kill one todo-app pod every 5 minutes.
   - `network-delay.yaml` — inject 200ms latency between app and Cloud SQL
     Proxy sidecar.
   - `network-partition.yaml` — simulate read-replica unreachability.

3. **Create a `scripts/run-chaos-experiment.sh`** wrapper:
   - Apply an experiment, wait for duration, collect SLO metrics, report
     pass/fail based on whether the availability SLO was maintained.

4. **Add a Runbook entry** for chaos experiment procedures.

**Files changed:**
- `terraform/chaos_mesh.tf` — new file.
- `binauthz-policy.yaml` — whitelist Chaos Mesh images.
- `test/chaos/experiments/*.yaml` — new experiment definitions.
- `scripts/run-chaos-experiment.sh` — new file.
- `docs/RUNBOOK.md` — chaos experiment section.

### 3.4 Incident Response Playbooks

**Problem:** The runbook has troubleshooting steps but no structured, automatable
incident response playbooks.

**Implementation:**

1. **Create `docs/playbooks/` directory** with structured playbooks:
   - `high-error-rate.md` — triggered by fast-burn SLO alert.
   - `database-unreachable.md` — triggered by circuit breaker open alert.
   - `region-failover.md` — triggered by regional health check failure.
   - `security-incident.md` — triggered by Cloud Armor block-rate spike.

2. **Each playbook follows a standard format:**
   ```
   ## Trigger
   ## Severity
   ## First Responder Actions (< 5 minutes)
   ## Investigation Steps
   ## Remediation Options
   ## Escalation Path
   ## Post-Incident
   ```

3. **Link playbooks from the Runbook** and from Cloud Monitoring alert
   documentation URLs.

**Files changed:**
- `docs/playbooks/*.md` — new files.
- `docs/RUNBOOK.md` — link to playbooks.
- `terraform/alerts.tf` — add `documentation` URLs to alert policies.

## 4. Verification Checklist

- [ ] Logs contain `trace_id` and link to Cloud Trace in the Console.
- [ ] Business SLI dashboard widget shows real data.
- [ ] Chaos Mesh installed; pod-kill experiment runs without SLO breach.
- [ ] All four playbooks reviewed and linked from alert policies.

## 5. Pitfalls & Considerations

- **Chaos in production:** Start with staging or a dedicated chaos namespace.
  Never run destructive experiments (e.g., node drain) without PDB protection.
- **Business SLI definition:** "90% completion in 7 days" is an example. The
  actual target should be set with stakeholders.
- **Log volume:** Adding trace IDs to every log line increases volume. Use
  sampling if costs become a concern.

## 6. Alternatives Considered

- **LitmusChaos instead of Chaos Mesh:** Both are CNCF projects. Chaos Mesh has
  a richer GKE integration and a dashboard UI. Either works.
- **PagerDuty / Opsgenie integration:** Valuable for real teams; out of scope
  for this reference implementation but the playbook format is compatible.
