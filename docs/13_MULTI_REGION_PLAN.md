# Multi-Region Expansion Plan (`milestone-13-multi-region`)

This document outlines the detailed plan to expand the `todo-app-go` implementation from a single region (`us-central1`) to a multi-region architecture (adding `us-east1`).

## Goals
- **Availability**: Increase SLI from 99.9% to 99.99%.
- **Resilience**: Survive a complete regional outage of `us-central1`.
- **Latency**: Serve users from the region closest to them.

## Architecture Overview
- **Compute**: Two GKE clusters, identical configuration.
  - Primary: `us-central1` (existing)
  - Secondary: `us-east1` (new)
- **Database**: Cloud SQL with Cross-Region Read Replica.
  - Primary: `us-central1`
  - Replica: `us-east1` (PROMOTION capable)
- **Ingress**: Global External Application Load Balancer (GCLB) with Multi-Cluster Ingress (MCI) or Multi-Cluster Gateway (MCG).
- **GitOps**: ArgoCD managing both clusters.

## Implementation Steps

### Phase 1: Preparation & Networking
- [x] **Quota Check**: Ensure `us-east1` has sufficient CPU/IP quotas.
- [x] **VPC Updates**: Ensure subnets exist for `us-east1` GKE and Services.
- [x] **Terraform Refactor**: Refactor Terraform to support multi-region modules (DRY principle).

### Phase 2: Database Expansion
- [x] **Create Replica**: Terraform changes to add `us-east1` Read Replica.
- [ ] **Verify Replication**: Check replication lag and connectivity.
- [ ] **Application Config**: Update app to be aware of read-replicas (optional optimization) or just ensure it connects to the local region's database endpoint (using Cloud SQL Proxy or internal DNS).
    - *Note*: If the app is write-heavy, writes MUST go to Primary. If using Cloud SQL Proxy, we need to ensure the proxy in `us-east1` points to the Primary in `us-central1` for writes, or we assume `us-east1` is read-only until failover.
    - *Decision*: For simplicity initially, `us-east1` app instances will connect to `us-central1` Primary for writes.

### Phase 3: Compute Replication
- [x] **Deploy GKE Cluster**: Provision `todo-cluster-east` in `us-east1`.
- [x] **Workload Identity**: Replicate creation of ServiceAccounts and IAM bindings.
- [x] **ArgoCD Registration**: Register the new cluster with the existing ArgoCD (hub-and-spoke or just multi-target).
- [x] **Deploy App**: Sync applications to the new cluster.

### Phase 4: Application Deployment & Traffic Management
- [x] **ArgoCD Registration**: Register the new cluster (Done).
- [x] **ArgoCD Application**:
    - Update `argocd-todo-app.yaml` to include a second Application for `us-east1`.
    - Commit and sync.
- [x] **Ingress Strategy**:
    - Implemented Multi-Cluster Ingress (MCI) with a static IP (`MCI_IP`).
    - Refactored Terraform and Kustomize to deploy MCI only to the config cluster (`us-central1`).
- [ ] **DNS Update**:
    - **ACTION REQUIRED**: Update A record for `DOMAIN_NAME` to point to `MCI_IP`.

### Phase 5: Verification & Drills
- [ ] **Traffic Distribution**: Verify traffic is routed to the closest region.
- [ ] **Failover Drill**:
    1.  Simulate `us-central1` outage (drain traffic).
    2.  Verify `us-east1` handles load.
    3.  (Advanced) Promote `us-east1` DB to primary and verify write capability.

## Verification Playbook

Use this playbook to complete the remaining Phase 2, 4, and 5 items.

### V1. Verify DB Replication (Phase 2)

```bash
# 1. Check replication status and lag
gcloud sql instances describe todo-app-db-replica \
  --format="yaml(replicaConfiguration,replicationCluster)"

# 2. Check replication lag metric in Cloud Monitoring
gcloud monitoring metrics list --filter="metric.type=cloudsql.googleapis.com/database/replication/replica_lag"

# 3. Functional test: insert a row on primary, verify it appears on replica
#    (connect via Cloud SQL Proxy on separate ports)
PGPASSWORD=<password> psql -h 127.0.0.1 -p 5432 -U todo-app-sa -d todo-app \
  -c "INSERT INTO todos (task, completed) VALUES ('replication-test', false);"

# Wait a few seconds for replication
sleep 5

PGPASSWORD=<password> psql -h 127.0.0.1 -p 5433 -U todo-app-sa -d todo-app \
  -c "SELECT * FROM todos WHERE task = 'replication-test';"

# 4. Clean up
PGPASSWORD=<password> psql -h 127.0.0.1 -p 5432 -U todo-app-sa -d todo-app \
  -c "DELETE FROM todos WHERE task = 'replication-test';"
```

**Pass criteria:** Replica returns the test row within 10 seconds.

### V2. Verify DNS & Traffic Routing (Phase 4-5)

```bash
# 1. Check the MCI static IP is assigned
kubectl get mci -n todo-app todo-app-ingress-global -o jsonpath='{.status.VIP}'
# Expected: MCI_IP

# 2. After DNS update — verify resolution
dig DOMAIN_NAME +short
# Expected: MCI_IP

# 3. Check traffic reaches both backends
#    (run from different regions or use curl with --resolve)
curl -s -o /dev/null -w "%{http_code} %{time_total}s" https://DOMAIN_NAME/healthz

# 4. Verify backend health on the GLB
gcloud compute backend-services get-health todo-app-backend-service --global
```

### V3. Failover Drill (Phase 5)

> **WARNING:** This drill will cause brief user-facing impact. Run during a
> maintenance window and notify stakeholders.

```bash
# === PRE-DRILL ===
# 1. Record baseline metrics
kubectl --context=gke_PROJECT_us-central1_todo-cluster get pods -n todo-app
kubectl --context=gke_PROJECT_us-east1_todo-cluster-east get pods -n todo-app

# 2. Start monitoring SLO dashboard in a separate tab

# === EXECUTE DRILL ===
# 3. Drain us-central1 traffic by scaling replicas to 0
kubectl --context=gke_PROJECT_us-central1_todo-cluster \
  scale rollout todo-app-go --replicas=0 -n todo-app

# 4. Wait 60 seconds for GLB health checks to detect the change

# 5. Verify us-east1 is serving traffic
curl -s -o /dev/null -w "%{http_code}" https://DOMAIN_NAME/healthz
# Expected: 200

# 6. Verify reads work (writes go to us-central1 primary — may fail or have latency)
curl -s https://DOMAIN_NAME/todos | jq length

# === ADVANCED: DB PROMOTION (optional) ===
# 7. Promote read replica to primary (DESTRUCTIVE — breaks replication)
# gcloud sql instances promote-replica todo-app-db-replica
# Then update us-east1 app config to point writes to the new primary

# === RESTORE ===
# 8. Scale us-central1 back up
kubectl --context=gke_PROJECT_us-central1_todo-cluster \
  scale rollout todo-app-go --replicas=2 -n todo-app

# 9. Wait for GLB to re-include us-central1 backends

# === POST-DRILL ===
# 10. Record SLO impact — did we stay within error budget?
# 11. Document findings in an incident report (even though planned)
```

**Pass criteria:**
- `us-east1` returns HTTP 200 within 90 seconds of draining `us-central1`.
- Read requests succeed from `us-east1`.
- SLO burn rate stays below fast-burn threshold during the drill.
- Restore completes and both regions are healthy within 5 minutes.

## Risks & Mitigations
- **Data Consistency**: Cross-region replication has latency. Strong consistency for writes is maintained by always writing to primary, but reads from replica might be stale.
- **Cost**: Doubling the infrastructure will double the compute/DB costs.
- **Complexity**: Debugging distributed systems is harder.

## Potential Pitfalls and Challenges Observed
During the implementation of Milestone 13, several challenges were encountered:

1.  **Binary Authorization Pattern Specificity**:
    *   **Challenge**: Gatekeeper and application images were blocked on the new cluster despite generic whitelist patterns. Patterns like `docker.io/openpolicyagent/*` failed to match when the Kubernetes event reported the image as `openpolicyagent/gatekeeper` (omitting the registry).
    *   **Solution**: Updated `binauthz-policy.yaml` and `terraform/binary-authorization.tf` to include explicit patterns matching both fully-qualified and short-name variants (e.g., `openpolicyagent/gatekeeper:*` and `openpolicyagent/gatekeeper-crds:*`).

2.  **Gatekeeper Installation Timeouts**:
    *   **Challenge**: Terraform's `helm_release` for Gatekeeper repeatedly timed out during the "pre-install" hook (CRD update job). This was caused by the hook job being blocked by the Binary Authorization issue mentioned above, leading to a "zombie" release state.
    *   **Solution**: Performed a manual deep cleanup of the `gatekeeper-system` namespace, manually installed the release to verify pod health, and then imported the working release into Terraform state. Set `wait = false` in `terraform/gatekeeper.tf` to prevent fragile timeout logic from breaking future applies.

3.  **ArgoCD Sync Chicken-and-Egg (CRDs)**:
    *   **Challenge**: ArgoCD failed to sync Gatekeeper `Constraints` because the `ConstraintTemplates` (which define the CRDs for those constraints) hadn't been processed by Gatekeeper yet.
    *   **Solution**: Manually seeded the `ConstraintTemplates` in the new cluster using `kubectl apply` to establish the CRDs, allowing ArgoCD to successfully sync the remaining resources in subsequent retries.
