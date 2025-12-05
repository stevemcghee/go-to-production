# Phase 3: HA and Scalability

## Goal Description
Implement High Availability (HA) and Scalability mitigations as outlined in the Risk Mitigation Plan. This involves upgrading the GKE cluster and Cloud SQL instance to regional (multi-zone) configurations and enabling Horizontal Pod Autoscaling (HPA) for the application.

## User Review Required
> [!WARNING]
> **Cost Implication**: Switching Cloud SQL to `REGIONAL` availability and upgrading the tier from `db-f1-micro` (which doesn't support HA) to a production-capable tier (e.g., `db-custom-1-3840` or `db-g1-small`) will increase costs.
> **Destructive Change**: Changing GKE from Zonal to Regional might require recreation of the cluster depending on Terraform provider behavior.

## Proposed Changes

### Terraform

#### [MODIFY] [main.tf](file:///Users/smcghee/src/todo-app-go/terraform/main.tf)
- **GKE Cluster**: Change `location` from `var.zone` to `var.region` to make it a regional cluster.
- **GKE Node Pool**: Change `location` to `var.region`.
- **Cloud SQL**:
    - Change `availability_type` to `REGIONAL`.
    - Change `tier` to `db-custom-1-3840` (minimum for HA) or `db-g1-small` if acceptable for dev/test but HA is needed. *Recommendation: `db-custom-1-3840` for true production HA.*

### Kubernetes

#### [NEW] [hpa.yaml](file:///Users/smcghee/src/todo-app-go/k8s/hpa.yaml)
- Create a `HorizontalPodAutoscaler` targeting the `todo-app` deployment.
- Min replicas: 2, Max replicas: 10.
- Target CPU utilization: 70%.

#### [MODIFY] [deployment.yaml](file:///Users/smcghee/src/todo-app-go/k8s/deployment.yaml)
- Add `resources` block to the container spec.
- Requests: CPU `100m`, Memory `128Mi`.
- Limits: CPU `500m`, Memory `512Mi`.
- *Note: These are required for HPA to function.*

## Verification Plan

### Automated Tests
- Run `terraform plan` to verify the infrastructure changes.
- Run `kubectl apply --dry-run=client -f k8s/` to verify manifest syntax.

### Manual Verification
- **Terraform**: Review the plan output to ensure it's creating regional resources.
- **Kubernetes**: Verify that `hpa.yaml` is correctly targeting the deployment and that the deployment has resources set.
