# Milestone 16: Cost Optimization

This milestone focuses on right-sizing infrastructure, preventing cost surprises,
and establishing a culture of cost awareness.

## 1. Checkout this Milestone

```bash
git checkout tags/milestone-16-cost-optimization
```

## 2. Goals

- **Right-size:** Ensure compute and database resources match actual usage.
- **Prevent surprises:** Detect anomalies before they become billing shocks.
- **Optimize contracts:** Evaluate committed use discounts for stable workloads.
- **Visibility:** Cost dashboard integrated with the existing monitoring stack.

## 3. Current Cost Baseline

| Category | Est. Daily Cost | Notes |
|----------|----------------|-------|
| GKE Management | $2.40 | Fixed fee (regional cluster) |
| Compute Nodes | ~$4.80 | 6x `e2-medium` (2 per zone, 3 zones) |
| Networking | ~$1.20 | GLB + data transfer |
| Observability | ~$2.40 | Logging, Trace, GKE Backup ingestion |
| Cloud SQL | ~$6.20 | Regional HA + Read Replica |
| **Total** | **~$17.00/day** | **~$510/month** |

With multi-region (Milestone 13), this approximately doubles to **~$34/day**.

## 4. What to Implement

### 4.1 GKE Autoscaling Tuning

**Problem:** Fixed node count (6 nodes) regardless of actual load. The todo app
uses a fraction of available CPU/memory during off-peak hours.

**Implementation options (evaluate and choose one):**

| Option | Pros | Cons |
|--------|------|------|
| **Cluster Autoscaler tuning** | Keep existing Standard cluster; reduce min nodes per zone from 2 to 1 | Slightly slower scale-up on traffic spike |
| **GKE Autopilot migration** | Pay-per-pod; no node management; automatic bin-packing | Less control; some workload restrictions |

**Recommended:** Start with Cluster Autoscaler tuning (lower risk).

1. **Update `terraform/main.tf`** — set `min_count = 1` per zone in the node pool.
2. **Add `autoscaling_profile = "OPTIMIZE_UTILIZATION"** to the cluster config.
3. **Verify** HPA and PDB still function correctly during scale-down.

**Estimated savings:** ~$1.60/day (remove 2 idle nodes during off-peak).

### 4.2 Cloud SQL Right-Sizing

**Problem:** The Cloud SQL instance tier may be over-provisioned for a todo app
with low write volume.

**Implementation:**

1. **Analyze usage** via Cloud SQL Insights (CPU, memory, connections, IOPS).
2. **Downsize if warranted:** e.g., from `db-custom-2-7680` to `db-f1-micro`
   (dev) or `db-custom-1-3840` (production).
3. **Update `terraform/main.tf`** with the new tier.
4. **Document the sizing rationale** so future operators know why.

**Estimated savings:** Up to ~$3/day depending on current vs. optimal tier.

### 4.3 Committed Use Discounts (CUDs)

**Problem:** All resources are on-demand pricing.

**Implementation:**

1. **Evaluate CUD eligibility** for resources expected to run for 1+ year:
   - GKE nodes (Compute Engine CUDs).
   - Cloud SQL instances (Cloud SQL CUDs).
2. **Document the analysis** in this milestone doc (don't auto-purchase in
   Terraform — CUDs require human approval due to commitment).
3. **Add a recommendation section** to the cost dashboard.

**Estimated savings:** 20-57% on committed resources.

### 4.4 Cost Anomaly Detection & Dashboard

**Problem:** No real-time visibility into cost trends. Budget alerts (Milestone 14)
catch overruns but don't show trends.

**Implementation:**

1. **Enable Cloud Billing anomaly detection** (built-in GCP feature):
   ```bash
   gcloud billing budgets update BUDGET_ID \
     --enable-default-iam-recipients
   ```

2. **Add a cost section to `terraform/dashboard.tf`:**
   - Daily cost trend (last 30 days).
   - Cost by service breakdown (GKE, Cloud SQL, Networking, Logging).
   - Cost per request (total cost / total requests from SLO metrics).

3. **Create a `scripts/cost-report.sh`:**
   - Query Cloud Billing export (BigQuery) for daily/weekly cost summary.
   - Output a Markdown table suitable for Slack or email.

**Files changed:**
- `terraform/dashboard.tf` — cost widgets.
- `scripts/cost-report.sh` — new file.

### 4.5 Resource Label Hygiene

**Problem:** Not all resources are labeled consistently, making cost allocation
harder.

**Implementation:**

1. **Enforce labels in Terraform** via a `locals` block with standard labels:
   ```hcl
   locals {
     standard_labels = {
       project     = "go-to-production"
       environment = "production"
       managed_by  = "terraform"
     }
   }
   ```

2. **Add a Gatekeeper policy** requiring `cost-center` and `environment` labels
   on all namespaces and deployments.

**Files changed:**
- `terraform/main.tf` — labels on all resources.
- `k8s/base/policies/` — new label constraint.

## 5. Verification Checklist

- [ ] Cluster autoscaler reduces nodes during off-peak (observe over 24h).
- [ ] Cloud SQL tier matches actual usage profile.
- [ ] Cost dashboard shows daily trend and per-service breakdown.
- [ ] CUD analysis documented with recommendation and ROI estimate.
- [ ] All Terraform-managed resources carry standard labels.

## 6. Pitfalls & Considerations

- **Autoscaler flapping:** If min nodes is too low and traffic is bursty, the
  autoscaler may scale up/down repeatedly. Set a `cooldown_period`.
- **Cloud SQL downtime:** Changing the instance tier requires a restart (a few
  minutes of downtime). Schedule during a maintenance window.
- **CUD commitment:** CUDs are non-cancellable. Only commit after at least 30
  days of stable usage data.
- **Billing export latency:** Cloud Billing data in BigQuery is delayed by
  several hours. Don't rely on it for real-time alerting (use budget alerts
  from Milestone 14 for that).

## 7. Alternatives Considered

- **Spot/Preemptible VMs:** Significant savings (~60-90%) but pods can be
  evicted at any time. Suitable for batch workloads but risky for a stateful
  web app without careful PDB and multi-zone setup. Consider for the load
  generator only.
- **GKE Autopilot:** Evaluated as option in 4.1. Good for simplicity but
  reduces control. Best suited for teams that want to minimize ops overhead.
