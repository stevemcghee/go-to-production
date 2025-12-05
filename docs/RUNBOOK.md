# Maintenance Runbook

## Rollback Procedures

### Cloud Deploy Rollback (Preferred)
If a bad release is detected, use Cloud Deploy to rollback to the previous release.

1. **Identify the previous release**:
   ```bash
   gcloud deploy releases list --delivery-pipeline=todo-app-pipeline --region=us-central1
   ```
2. **Promote the previous release**:
   ```bash
   gcloud deploy releases promote --release=[PREVIOUS_RELEASE_NAME] \
     --delivery-pipeline=todo-app-pipeline \
     --region=us-central1 \
     --to-target=production
   ```

### Manual Rollback (Emergency)
If Cloud Deploy is unavailable, manually apply the previous Kubernetes manifests.

1. **Checkout the previous stable commit**:
   ```bash
   git checkout [PREVIOUS_COMMIT_SHA]
   ```
2. **Apply manifests**:
   ```bash
      kubectl apply -f k8s/ -n todo-app   ```

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

## Application Resilience Features

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

### Read Replica
Read queries (`GET /todos`) are automatically routed to a read replica for improved performance and availability.

**Failover**: If read replica is unavailable, application falls back to primary database automatically.

**Verify Connection**:
```bash
# Check both connections are active
kubectl logs -l app=todo-app-go -n todo-app | grep "Successfully connected"
# Should see: "Successfully connected to PRIMARY database"
# AND: "Successfully connected to READ REPLICA"
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
**Mitigation**: Currently **UNMITIGATED**. The application resides only in `us-central1`.
**Recovery**:
1.  Spin up infrastructure in a new region (e.g., `us-east1`) using Terraform (update `region` variable).
2.  Restore Cloud SQL database from backup to the new region (Cross-Region Restore).
3.  Update DNS to point to the new Load Balancer IP.

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
