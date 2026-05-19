# Maintenance Runbook

## Rollback Procedures

### ArgoCD Rollback (GitOps - Preferred)
Since the cluster state is managed via GitOps, the best way to rollback is to revert the commit in Git.

1. **Revert the commit**:
   ```bash
   git revert [BAD_COMMIT_SHA]
   git push origin main
   ```
2. **Verify Sync**:
   ArgoCD will detect the revert and sync the cluster back to the previous stable state within 3 minutes.
3. **Manual Trigger** (if urgent):
   ```bash
   kubectl patch app todo-app -n argocd -p '{"metadata": {"annotations": {"argocd.argoproj.io/refresh": "hard"}}}' --type merge
   ```

### Cloud Deploy Rollback (Legacy/Canary)
If you are using Cloud Deploy for advanced canary rollouts (e.g., milestone 6), use the following:


### Manual Rollback (Emergency)
If Cloud Deploy is unavailable, manually apply the previous Kubernetes manifests.

1. **Checkout the previous stable commit**:
   ```bash
   git checkout [PREVIOUS_COMMIT_SHA]
   ```
2. **Apply manifests**:
   ```bash
   kubectl apply -f k8s/ -n todo-app
   ```

## Emergency Fallback: Cloud Deploy

If ArgoCD is unavailable (e.g., control plane failure, Git provider outage) or if you need to bypass GitOps for an immediate emergency release, use Cloud Deploy.

### 1. Suspend ArgoCD (If controller is alive)
If the ArgoCD controller is still running, you must disable automatic synchronization to prevent it from overwriting your Cloud Deploy changes.

```bash
# Disable auto-sync and self-heal
kubectl patch app todo-app -n argocd -p '{"spec": {"syncPolicy": {"automated": null}}}' --type merge
```

### 2. Trigger Cloud Deploy Release
Use the pre-configured delivery pipeline to push the desired version directly to the cluster.

```bash
# Create a release via Cloud Deploy
gcloud deploy releases create emergency-$(date +%s) \
  --delivery-pipeline=todo-app-pipeline \
  --region=us-central1 \
  --images=todo-app-go=[IMAGE_TAG_OR_DIGEST]
```

### 3. Resume ArgoCD Orchestration
Once the emergency is resolved and the fix has been committed to Git, re-enable ArgoCD to restore the GitOps "Source of Truth".

```bash
# Re-enable automated sync
kubectl patch app todo-app -n argocd -p '{"spec": {"syncPolicy": {"automated": {"prune": true, "selfHeal": true}}}}' --type merge
```

## Observability & Dashboards

### Cloud Monitoring Dashboard
We have a custom dashboard aggregating GKE Workload, Alerting, and Cloud SQL storage metrics.

*   **[Todo App Production Dashboard](https://console.cloud.google.com/monitoring/dashboards/builder/3db86f35-283e-445b-be65-8bb076e09210;customDuration=today?project=irtco-sandbox&pageState=(%22eventTypes%22:(%22selected%22:%5B%22GKE_WORKLOAD_DEPLOYMENT%22,%22CLOUD_ALERTING_ALERT%22,%22CLOUD_SQL_STORAGE%22%5D)))**

### Accessing ArgoCD
ArgoCD is the control plane for our GitOps workflows. To access it:

1.  **Port-forward the UI**:
    ```bash
    kubectl port-forward svc/argocd-server -n argocd 8080:443
    ```
2.  **Login**:
    *   **URL**: `https://localhost:8080` (Bypass TLS warning)
    *   **User**: `admin`
    *   **Password**: Run this command to retrieve:
        ```bash
        kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d; echo
        ```

## Cloud Trace

The application uses OpenTelemetry to export distributed traces to Cloud Trace.

### Viewing Traces

1. **Access Cloud Trace**:
   - Go to Cloud Console → Trace → Trace List
   - Filter by service name: `todo-app-go`

2. **Analyze Request Flow**:
   - Click on any trace to see the full request timeline
   - View database query performance
   - Identify slow operations or errors

3. **Common Trace Queries**:
   ```bash
   # View traces with errors
   Filter: HasError=true
   
   # View slow requests (>500ms)
   Filter: LatencyMs>500
   ```

### Troubleshooting Trace Issues

If traces aren't appearing:

1. **Check permissions**:
   ```bash
   gcloud projects get-iam-policy $(gcloud config get-value project) \
     --flatten="bindings[].members" \
     --filter="bindings.members:serviceAccount:todo-app-sa@*" \
     --format="table(bindings.role)"
   ```
   Should include `roles/cloudtrace.agent`

2. **Check API is enabled**:
   ```bash
   gcloud services list --enabled --filter="name:cloudtrace.googleapis.com"
   ```

3. **Check application logs for export errors**:
   ```bash
   kubectl logs -l app=todo-app-go -n todo-app | grep "Cloud Trace"
   ```

## Application Robustness Features

### Automatic Retries
The application implements exponential backoff retries for all database operations.

**Configuration**:
- Initial interval: 100ms
- Max interval: 2s
- Max elapsed time: 5s

**Behavior**: Transient database errors (network blips, connection pool exhaustion) are automatically retried. Check logs for retry warnings:
```bash
kubectl logs -l app=todo-app-go -n todo-app | grep "retrying"
```

### Circuit Breaker
A circuit breaker protects against cascading failures when the database is consistently unavailable.

**States**:
- **Closed**: Normal operation, all requests pass through
- **Open**: After 60% failure rate (min 3 requests), requests fail immediately with `503 Service Unavailable`
- **Half-Open**: After 30s, allows 1 request to test if service recovered

**Monitoring**:
Check circuit breaker state changes:
```bash
kubectl logs -l app=todo-app-go -n todo-app | grep "Circuit Breaker state changed"
```

**Recovery**: Circuit breaker auto-recovers when database becomes healthy. No manual intervention needed.

### Read Replica & Multi-Region DB Routing
Read queries (`GET /todos`) are automatically routed to a read replica for improved performance
and availability. The routing logic includes:

- **Read-after-write consistency**: After any write (POST/PUT/DELETE), reads are routed to
  primary for 2 seconds to avoid stale data from replication lag.
- **Automatic failover**: If the read replica is unavailable, reads fall back to primary.

**Verify Connection**:
```bash
# Check both connections are active
kubectl logs -l app=todo-app-go -n todo-app | grep "Successfully connected"
# Should see: "Successfully connected to PRIMARY database"
# AND: "Successfully connected to READ REPLICA"
```

**Monitor DB Routing** (via Prometheus metrics):
```bash
# Check which pool is serving reads
curl -s <POD_IP>:8080/metrics | grep db_reads_total
# db_reads_total{source="replica"}   — normal reads from replica
# db_reads_total{source="primary"}   — reads routed to primary (read-after-write)
# db_reads_total{source="primary_fallback"} — replica failed, fell back to primary

# Check write volume
curl -s <POD_IP>:8080/metrics | grep db_writes_total
```

**Detailed Health Check** (multi-region debugging):
```bash
# Returns JSON with region, cluster, DB pool status, and current read routing
curl -H "Accept: application/json" https://todo-irtco-sandbox.example.com/healthz
```

## Service Level Objectives (SLOs)

The application is monitored using two key SLOs that define reliability targets:

### Availability SLO: 99.9%
**Target**: 99.9% of HTTP requests must succeed (non-5xx responses) over a 28-day rolling window.

**Error Budget**: 0.1% of requests can fail (approximately 43 minutes of downtime per month).

**Monitoring**:
```bash
# View SLO status in Cloud Console
gcloud monitoring slos list --service=todo-app-go-svc
```

**Alerts**:
- **Fast Burn** (10x rate): Fires when error budget would be exhausted in ~3 days
  - Action: Immediate incident response required
- **Slow Burn** (2x rate): Fires when error budget consumption is elevated
  - Action: Investigate and plan proactive fixes

### Latency SLO: 95% < 500ms
**Target**: 95% of HTTP requests must complete within 500ms over a 28-day rolling window.

**Error Budget**: 5% of requests can exceed 500ms latency.

### Responding to SLO Violations

When an SLO burn rate alert fires:

1. **Assess Impact**:
   ```bash
   # Check current error rate
   kubectl logs -l app=todo-app-go -n todo-app | grep "error"
   
   # Check circuit breaker state
   kubectl logs -l app=todo-app-go -n todo-app | grep "Circuit Breaker"
   ```

2. **Identify Root Cause**:
   - Database issues? Check Cloud SQL metrics in console
   - Application errors? Review logs for exceptions
   - External dependency? Check network/DNS

3. **Take Action**:
   - Rollback recent deployment if correlation found
   - Scale up pods if load-related: `kubectl scale deployment todo-app-go --replicas=5 -n todo-app`
   - Engage on-call engineer if fast burn alert

4. **Document**:
   - Log incident in tracking system
   - Document root cause and remediation
   - Review and update mitigation strategies

## Load Generator

A synthetic load generator runs continuously to:
- Validate SLO monitoring is working
- Keep application warm and connection pools active
- Generate baseline metrics data
- Detect issues proactively

**Configuration**:
- Runs every minute via Kubernetes CronJob
- Generates 2 requests per minute:
  - GET /todos (exercises read replica)
  - GET /healthz (validates liveness)

**Monitoring**:
```bash
# Check load generator status
kubectl get cronjob todo-app-load-generator -n todo-app

# View recent job runs
kubectl get jobs -n todo-app | grep load-generator

# Check logs from last run
kubectl logs -l app=load-generator -n todo-app --tail=20
```

**Adjusting Load**:
To change request frequency, edit `k8s/load-generator.yaml`:
```bash
# Edit the schedule (currently: */1 * * * * = every minute)
kubectl edit cronjob todo-app-load-generator -n todo-app

# Or modify the number of requests in the curl loop
```

**Disabling**:
```bash
# Suspend load generation
kubectl patch cronjob todo-app-load-generator -p '{"spec":{"suspend":true}}' -n todo-app

# Resume
kubectl patch cronjob todo-app-load-generator -p '{"spec":{"suspend":false}}' -n todo-app
```

## Troubleshooting

### Database Connectivity Issues
**Symptoms**: HTTP 500 errors, "password authentication failed" logs.

1. **Check Cloud SQL Proxy**:
   ```bash
   kubectl logs -l app=todo-app-go -c cloudsql-proxy -n todo-app
   ```
2. **Verify Workload Identity**:
   Ensure the Kubernetes ServiceAccount is annotated correctly:
   ```bash
   kubectl describe sa todo-app-sa -n todo-app
   ```
3. **Check IAM Permissions**:
   Ensure the Google Service Account has `roles/cloudsql.instanceUser`.

### HTTP 403 Forbidden Errors

**Symptoms**: POST/PUT/DELETE requests fail with 403, browser console shows "Forbidden".

**Common Causes**:

1. **Cloud Armor Security Policy Blocking Requests**:
   ```bash
   # Check if security policy is attached
   gcloud compute backend-services list --filter="name~todo-app" \
     --format="table(name,securityPolicy)"
   ```
   
   If a security policy is attached and causing false positives:
   ```bash
   # Temporarily remove it
   BACKEND_SERVICE=$(gcloud compute backend-services list --filter="name~todo-app" --format="value(name)")
   gcloud compute backend-services update $BACKEND_SERVICE --global --security-policy=""
   ```

2. **Check Cloud Armor Logs**:
   ```bash
   gcloud logging read "resource.type=http_load_balancer AND jsonPayload.enforcedSecurityPolicy.name!=null" \
     --limit=20 --format=json
   ```

3. **Content Security Policy (CSP) Issues**:
   - Check browser console for CSP violations
   - CSP is configured in `main.go` in `securityHeadersMiddleware`
   - Current policy allows fonts, styles, and scripts from trusted sources

### High Load / Scaling Issues
**Symptoms**: High latency, HPA maxed out.

Resource requests and limits are set on the application container to ensure predictable performance and avoid resource contention.

1. **Check HPA Status**:
   ```bash
   kubectl get hpa -n todo-app
   ```
2. **Increase Max Replicas** (if needed):
   Edit `k8s/hpa.yaml` and increase `maxReplicas`.
   ```bash
   kubectl apply -f k8s/hpa.yaml -n todo-app
   ```
3. **Check Database Load**:
   Check Cloud SQL CPU utilization in Cloud Console. If high, consider upgrading the instance tier (requires downtime).

## GKE Backup and Restore

A GKE Backup Plan has been configured to automatically back up all cluster resources and persistent volumes.

### Enabling GKE Backup for GKE

1. **Enable the API**:
   ```bash
   gcloud services enable gke-backup.googleapis.com
   ```

2. **Deploy the Backup Plan**:
   The backup plan is defined in `k8s/backup-plan.yaml`. To deploy it, use the `backup` profile in skaffold:
   ```bash
   skaffold deploy -p backup
   ```

### Restoring from a Backup

1. **List Backups**:
   ```bash
   gcloud beta container backup-restore backups list --location=us-central1
   ```

2. **Restore**:
   ```bash
   gcloud beta container backup-restore restores create my-restore \
     --backup=my-backup --location=us-central1
   ```

## Disaster Recovery
...
**Note**: For cluster-level disaster recovery, consider using the GKE Backup plan. See the "GKE Backup and Restore" section for more details.
...


### Cluster Failure Scenarios

#### Zone Failure
**Risk**: One zone in `us-central1` becomes unavailable.
**Mitigation**: We use a **Regional GKE Cluster**. The control plane is replicated across zones, and nodes are distributed.
**Action**: Kubernetes will automatically reschedule pods to healthy zones. No manual intervention required, but capacity might be reduced.

#### Region Failure
**Risk**: The entire `us-central1` region becomes unavailable.
**Mitigation**: **MITIGATED** (Milestone 13). Multi-region infrastructure deployed:
- GKE clusters in `us-central1` (primary) and `us-east1` (secondary)
- Cloud SQL primary in `us-central1` with read replica in `us-east1`
- Multi-Cluster Ingress (MCI) with global load balancing
- Region-aware DB routing with read-after-write consistency

**Automatic behavior**: The Global Load Balancer stops routing traffic to unhealthy
`us-central1` backends. `us-east1` backends continue to serve **read traffic** automatically
from the local read replica.

**Manual failover procedure for writes** (estimated time: 10–15 minutes):

1.  **Confirm the outage** is regional (not just a zone or network blip):
    ```bash
    # Check GKE cluster health
    gcloud container clusters list --format="table(name,location,status)"
    # Check Cloud SQL instance health
    gcloud sql instances list --format="table(name,region,state)"
    ```

2.  **Promote the Cloud SQL replica** in `us-east1` to a standalone primary:
    ```bash
    gcloud sql instances promote-replica todo-app-db-instance-replica
    ```
    Wait for state to become `RUNNABLE` (~2–5 minutes).

3.  **Update the Secret Manager secret** so the `us-east1` app writes to the promoted instance:
    ```bash
    # The promoted replica keeps its connection name; the Cloud SQL Proxy sidecar
    # in us-east1 already connects to it on port 5433. Update the secret so
    # db_host points to the replica proxy port.
    gcloud secrets versions add todo-app-secret --data-file=- <<'EOF'
    {
      "db_user": "todo-app-sa@irtco-sandbox.iam",
      "db_name": "todoapp_db",
      "db_host": "127.0.0.1",
      "db_port": "5433",
      "db_read_host": "127.0.0.1",
      "db_read_port": "5433"
    }
    EOF
    ```

4.  **Restart the app pods** in `us-east1` to pick up the new secret:
    ```bash
    kubectl rollout restart rollout/todo-app-go -n todo-app \
      --context=gke_irtco-sandbox_us-east1_todo-app-cluster-secondary
    ```

5.  **Verify** write operations succeed:
    ```bash
    curl -X POST https://todo-irtco-sandbox.example.com/todos \
      -H "Content-Type: application/json" \
      -d '{"task":"failover-test"}'
    # Check detailed health
    curl -H "Accept: application/json" https://todo-irtco-sandbox.example.com/healthz
    ```

6.  **Monitor** the promoted instance and application metrics:
    ```bash
    # Check DB routing metrics
    curl -s https://todo-irtco-sandbox.example.com/metrics | grep db_reads_total
    curl -s https://todo-irtco-sandbox.example.com/metrics | grep db_writes_total
    ```

**Recovery after primary region comes back** (~30 minutes):

1.  **Do NOT immediately revert** — ensure primary region is stable for ≥15 minutes.
2.  **Create a new replica** from the promoted instance:
    ```bash
    gcloud sql instances create todo-app-db-instance-new \
      --master-instance-name=todo-app-db-instance-replica \
      --region=us-central1 --tier=db-custom-1-3840 \
      --database-version=POSTGRES_14 \
      --database-flags=cloudsql.iam_authentication=on
    ```
3.  **Wait for replication** to catch up (check replica lag in Cloud Console).
4.  **Restore original secret** and restart pods in both regions.
5.  **Document the incident** — update the post-incident report with timeline and learnings.

### Database Restore

#### Point-in-Time Recovery (PITR)
To restore the database to a specific timestamp (e.g., before an accidental deletion):

1.  **Identify Timestamp**: Determine the exact time of the incident (in RFC 3339 format, e.g., `2025-12-03T12:00:00Z`).
2.  **Clone Instance**: Create a new instance from the backup (safer than overwriting).
    ```bash
    gcloud sql instances clone todo-app-db-instance todo-app-db-recovered \
      --point-in-time="2025-12-03T12:00:00Z"
    ```
3.  **Verify Data**: Connect to `todo-app-db-recovered` and verify the data.
4.  **Promote**: Update the application to use the new instance IP/connection name.

#### Full Backup Restore
To restore from a specific daily backup (overwrites current data):

1.  **List Backups**:
    ```bash
    gcloud sql backups list --instance=todo-app-db-instance
    ```
2.  **Restore**:
    ```bash
    gcloud sql backups restore [BACKUP_ID] --restore-instance=todo-app-db-instance
    ```
    *Warning: This will overwrite the current database state.*

## Common Pitfalls & Troubleshooting

### Multi-Cluster Ingress (MCI) Configuration

#### Static IP Assignment
**Issue**: The `networking.gke.io/static-ip` annotation on the `MultiClusterIngress` resource failed to apply when using a variable placeholder (e.g., `${todo_app_global_ip}`) or a resource name that hadn't propagated.
**Solution**: Use the **literal static IP address** (e.g., `MCI_IP`) in the annotation.
**Check**: Verify the IP is assigned by checking the VIP status:
```bash
kubectl get mci -n todo-app todo-app-ingress-global -o yaml
```

#### HTTPS & TLS Certificates
**Issue**: The site is reachable via IP but fails to load via the domain with HTTPS.
**Solution**: A `ManagedCertificate` resource must be created and linked to the MCI.
1. Ensure `k8s/base/managed-certificate.yaml` exists and lists the correct domain.
2. Add the annotation `networking.gke.io/managed-certificates: "todo-app-cert"` to the `MultiClusterIngress`.
**Note**: Google-managed certificates can take up to **60 minutes** to provision.

### GitOps Synchronization (ArgoCD)

**Issue**: Changes made manually via `kubectl apply` (like updating the MCI static IP) disappear or revert after a few minutes.
**Cause**: ArgoCD monitors the Git repository as the "Source of Truth" and reverts any manual changes that differ from the repo.
**Solution**: **Always commit changes to Git.**
```bash
git add k8s/base/multi-cluster-ingress.yaml
git commit -m "Update static IP"
git push origin main
```

### Terraform & Helm Timeouts

**Issue**: `terraform apply` fails with a timeout error for Helm releases (e.g., `gatekeeper_secondary`).
**Workaround**:
1. Temporarily comment out the failing `helm_release` resource in Terraform.
2. Run `terraform apply` to provision other critical resources (like IPs).
3. Uncomment the resource and re-run `terraform apply`, or troubleshoot the specific cluster connectivity/resource limits causing the timeout.

---

## Planned Operational Procedures (Milestones 14–16)

The following sections describe procedures that will be implemented in upcoming milestones.
As each milestone is completed, move the relevant section above this header and remove the
"planned" annotation.

### Quota Exhaustion Alert Response (Milestone 14)

**Trigger**: Cloud Monitoring alert "GCP Quota Usage > 80%".

**Severity**: Warning (80%), Critical (95%).

**Actions**:
1. **Identify the quota** from the alert payload (e.g., `compute.googleapis.com/cpus`, `compute.googleapis.com/in_use_addresses`).
2. **Check current usage**:
   ```bash
   gcloud compute project-info describe --project=PROJECT_ID \
     --format="table(quotas.metric,quotas.usage,quotas.limit)" \
     | grep -i <METRIC>
   ```
3. **Short-term**: If legitimate growth, request a quota increase:
   ```bash
   gcloud compute project-info update --project=PROJECT_ID \
     --quota-increase-request
   ```
4. **Investigate**: If unexpected, check for runaway autoscalers, leaked resources, or
   misconfigured Terraform that is over-provisioning.

### Billing Spike Response (Milestone 14)

**Trigger**: Cloud Billing budget alert at 50% / 80% / 100% of monthly budget.

**Actions**:
1. **Check the billing report** in Cloud Console → Billing → Reports.
2. **Identify the cost driver** (usually Compute Engine or Cloud SQL).
3. **If autoscaler runaway**: Check HPA status and cluster autoscaler logs.
   ```bash
   kubectl get hpa -n todo-app
   kubectl logs -l component=cluster-autoscaler -n kube-system --tail=50
   ```
4. **If unexpected resource**: List all running instances and check for orphans:
   ```bash
   gcloud compute instances list --project=PROJECT_ID
   gcloud sql instances list --project=PROJECT_ID
   ```
5. **Escalate** if 100% threshold is breached — consider scaling down non-critical
   environments.

### Backup Restore Drill (Milestone 14)

**Schedule**: Monthly (1st of each month, 03:00 UTC, automated via CronJob).

**What it does**:
1. Clones the Cloud SQL instance to a temporary `todo-app-db-drill-YYYYMMDD` instance.
2. Connects and runs `SELECT count(*) FROM todos` to verify data integrity.
3. Deletes the temporary instance.
4. Logs PASS/FAIL to Cloud Logging with label `drill=backup-restore`.

**Manual trigger**:
```bash
kubectl create job --from=cronjob/backup-restore-drill drill-manual-$(date +%s) -n todo-app
```

**If the drill fails**:
1. Check Cloud SQL instance status — is the primary healthy?
2. Check PITR availability: `gcloud sql backups list --instance=todo-app-db-instance`
3. Attempt manual restore (see "Database Restore" section above).
4. If repeated failures, investigate Cloud SQL service health and open a support case.

### Audit & Access Review (Milestone 14)

**Schedule**: Quarterly.

**Procedure**:
1. **Review IAM bindings** for the project:
   ```bash
   gcloud projects get-iam-policy PROJECT_ID \
     --format="table(bindings.role,bindings.members)" | sort
   ```
2. **Check for over-privileged accounts** — no user should have `roles/owner` in production.
3. **Review audit logs** for suspicious `SetIamPolicy` events:
   ```bash
   gcloud logging read 'protoPayload.methodName="SetIamPolicy"' \
     --project=PROJECT_ID --limit=20 --format=json
   ```
4. **Rotate service account keys** if any exist (prefer Workload Identity instead).
5. **Document findings** and remediate any issues.

### Chaos Experiment Procedure (Milestone 15)

**Prerequisites**: Chaos Mesh installed, SLO monitoring active.

**Steps**:
1. **Select an experiment** from `test/chaos/experiments/`.
2. **Notify stakeholders** and confirm maintenance window.
3. **Start SLO recording** (note current error budget remaining).
4. **Apply the experiment**:
   ```bash
   kubectl apply -f test/chaos/experiments/pod-kill.yaml
   ```
5. **Monitor** the SLO dashboard for 10–15 minutes.
6. **Stop the experiment**:
   ```bash
   kubectl delete -f test/chaos/experiments/pod-kill.yaml
   ```
7. **Evaluate**: Did the system stay within SLO? Did circuit breakers activate correctly?
8. **Document findings** in a brief post-experiment report.

### Incident Response Playbooks (Milestone 15)

Structured playbooks will be created in `docs/playbooks/`:
- `high-error-rate.md` — triggered by fast-burn SLO alert
- `database-unreachable.md` — triggered by circuit breaker open
- `region-failover.md` — triggered by regional health check failure
- `security-incident.md` — triggered by Cloud Armor block spike

Each follows the format: Trigger → Severity → First Responder Actions → Investigation →
Remediation → Escalation → Post-Incident.

See [15_ADVANCED_OBSERVABILITY.md](15_ADVANCED_OBSERVABILITY.md) for full details.
