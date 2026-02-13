# Milestone 17: Multi-Cloud Active-Active

This milestone eliminates the single-provider dependency by deploying a parallel,
independently-operational stack on a second cloud provider.

## 1. Checkout this Milestone

```bash
git checkout tags/milestone-17-multi-cloud
```

## 2. Goals

- **Provider Independence:** Survive a total GCP outage (the "unthinkable" scenario).
- **Active-Active:** Both clouds serve production traffic simultaneously — not a
  cold standby that has never been tested under real load.
- **Data Sovereignty:** Demonstrate the ability to keep data within regulatory
  boundaries by placing stacks in specific jurisdictions.
- **Negotiation Leverage:** Eliminate vendor lock-in as a business risk.

## 3. Architecture

```
                    ┌──────────────────┐
         ┌─────────┤  DNS (Cloudflare) ├─────────┐
         │         └──────────────────┘         │
         ▼                                       ▼
  ┌──────────────┐                       ┌──────────────┐
  │   GCP GLB    │                       │   AWS ALB    │
  │  Cloud Armor │                       │   WAF v2     │
  └──────┬───────┘                       └──────┬───────┘
         │                                       │
  ┌──────▼───────┐                       ┌──────▼───────┐
  │  GKE Cluster │                       │  EKS Cluster │
  │  (us-central1│                       │  (us-east-1) │
  │   + us-east1)│                       │              │
  └──────┬───────┘                       └──────┬───────┘
         │                                       │
  ┌──────▼───────┐    replication        ┌──────▼───────┐
  │  Cloud SQL   │◄────────────────────►│  Aurora PG   │
  │  (Primary)   │   bi-directional      │  (Primary)   │
  └──────────────┘   or CRR + CDC        └──────────────┘
```

### Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Second cloud | AWS | Largest alternative; best Kubernetes (EKS) parity with GKE |
| Database sync | Logical replication or CDC (Debezium) | Cloud SQL ↔ Aurora don't support native cross-cloud replication |
| DNS routing | Cloudflare (external to both clouds) | Avoids depending on either provider's DNS for failover |
| Container registry | Mirror to both ECR and Artifact Registry | Each cloud pulls from its own local registry |
| IaC | Terraform (already used) | Same tool, separate state files per provider |
| GitOps | ArgoCD hub managing both GKE and EKS | Single control plane, multi-cluster |

## 4. What to Implement

### 4.1 AWS Foundation

1. **Create `terraform/aws/` directory** with a parallel stack:
   - EKS cluster with managed node groups
   - Aurora PostgreSQL (compatible with Cloud SQL schema)
   - ALB + WAF v2 (mirrors Cloud Armor rules)
   - ECR repository for container images
   - IAM roles for EKS pods (IRSA — equivalent to Workload Identity)

2. **Mirror the CI/CD pipeline** in `.github/workflows/build-test.yml`:
   - After building and pushing to Artifact Registry, also push to ECR.
   - Sign the ECR image with Cosign (same keyless flow).

3. **Register EKS with ArgoCD** (same pattern as the `us-east1` GKE cluster).

### 4.2 Cross-Cloud Data Replication

1. **Deploy Debezium Connect** as a Kubernetes workload:
   - Captures Change Data Capture (CDC) events from Cloud SQL.
   - Publishes to a Kafka/Pub-Sub bridge.
   - Consumes on the AWS side and applies to Aurora.

2. **Alternatively, use PostgreSQL logical replication:**
   - Cloud SQL supports `pglogical` or native logical replication.
   - Aurora supports logical replication subscriptions.
   - Simpler than Debezium but limited to PostgreSQL-to-PostgreSQL.

3. **Conflict resolution:** For an active-active write setup, implement
   last-writer-wins with vector clocks or restrict writes to a single
   primary region and use the other as hot-standby.

### 4.3 DNS-Based Traffic Management

1. **Move DNS to Cloudflare** (external to both GCP and AWS):
   - Weighted routing: 70% GCP / 30% AWS initially.
   - Health checks on both endpoints.
   - Automatic failover: if one cloud fails health checks, route 100% to the other.

2. **Latency-based routing** as an alternative:
   - Cloudflare or Route 53 routes users to the nearest healthy endpoint.

### 4.4 Unified Observability

1. **Aggregate metrics** from both clouds into a single pane:
   - Option A: Grafana Cloud (vendor-neutral).
   - Option B: Export AWS metrics to GCP Cloud Monitoring via OpenTelemetry Collector.

2. **Unified alerting** — SLOs must span both clouds:
   - Global availability = (GCP success + AWS success) / (GCP total + AWS total).

### 4.5 Edge & Static Assets

1. **Deploy static assets to Cloudflare Pages or Workers:**
   - CSS, JS, images served from the edge (300+ PoPs).
   - Reduces load on origin servers.
   - Survives both GCP and AWS outages for read-only content.

2. **Optionally, add a Cloudflare Worker as an API gateway:**
   - Routes API requests to the nearest healthy backend.
   - Adds an additional caching layer.

## 5. Verification Checklist

- [ ] EKS serves traffic independently when GKE is drained.
- [ ] GKE serves traffic independently when EKS is drained.
- [ ] Data written to GCP appears in AWS within replication SLA (< 5s).
- [ ] DNS failover completes within 60 seconds of health check failure.
- [ ] Static assets load from Cloudflare even when both origins are down.
- [ ] Unified SLO dashboard reflects both clouds accurately.

## 6. Pitfalls & Considerations

- **Cost:** Running two full stacks roughly triples total cost. This is the
  price of true provider independence.
- **Data consistency:** Cross-cloud replication introduces latency and conflict
  potential. Choose consistency model carefully (strong for writes, eventual
  for reads).
- **Operational complexity:** Two clouds means two sets of IAM, networking,
  and debugging tools. Invest in a unified runbook.
- **Terraform state:** Keep separate state files per cloud. Never mix GCP and
  AWS resources in the same state.
- **Credential management:** Each cloud has its own secret management (Secret
  Manager vs. Secrets Manager). Use a unified abstraction or replicate secrets.

## 7. Alternatives Considered

- **GCP + Azure instead of GCP + AWS:** Viable but EKS has better Kubernetes
  parity with GKE than AKS in practice.
- **Cold standby instead of active-active:** Cheaper but untested failover is
  not reliable failover. Active-active ensures the secondary is always
  battle-tested.
- **Multi-cloud Kubernetes (Anthos / EKS Anywhere):** Adds complexity and
  vendor lock-in to the multi-cloud abstraction itself. Vanilla Kubernetes
  on each cloud is more portable.
