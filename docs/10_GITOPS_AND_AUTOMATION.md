# Milestone 10: GitOps & Automation

This document outlines the transition from push-based deployments to a pull-based GitOps model and the implementation of automated security checks.

## 1. Checkout this Milestone

To deploy this version of the infrastructure:

```bash
git checkout tags/milestone-gitops
```

## 2. What was Implemented?

We replaced manual/imperative deployment steps with a declarative GitOps workflow.

**Key Features:**
*   **ArgoCD**: Installed as the GitOps controller in the GKE cluster.
    *   *Benefit*: Cluster state is now continuously reconciled with the Git repository. Manual "hotfixes" or drift are automatically reverted.
*   **Declarative Infrastructure**: Added Terraform modules to manage ArgoCD itself via Helm.
*   **Security Quick Wins**:
    *   **Dependabot**: Automated dependency updates for Go modules and Docker images.
    *   **Pre-commit Hooks**: Local checks for secrets (gitleaks) and YAML formatting to catch issues before they reach the repo.

## 3. Pitfalls & Considerations

*   **Dependency on CRDs**: We encountered an issue where GKE Backup CRDs (`BackupPlan`) were not immediately available or were misconfigured. We temporarily removed this resource to ensure the GitOps pipeline could establish its initial sync.
*   **Permission Loop**: ArgoCD needs significant permissions (`cluster-admin` level or similar) to manage resources across namespaces. We had to ensure the user applying the Terraform had sufficient GCP permissions (`container.admin`) to grant these roles.
*   **State Locking**: Terraform state was locked by a previous operation. In a production environment, this requires careful coordination (e.g., using a state locking mechanism like GCS or a dedicated CI service).

## 4. Alternatives Considered

*   **Cloud Deploy (Managed Service)**: We moved away from Cloud Deploy as the *primary* driver to achieve a multi-repo/multi-cluster friendly "Pull" model. Cloud Deploy is still useful for manual approvals and canary logic, but ArgoCD provides better visibility into drift.
*   **FluxCD**: A strong alternative to ArgoCD.
    *   *Why ArgoCD?* Powerful UI for visualization and easier "App of Apps" pattern management for complex projects.

## 5. Usage Instructions

### Accessing ArgoCD
1. **Port-forward the UI**:
   ```bash
   kubectl port-forward svc/argocd-server -n argocd 8080:443
   ```
2. **Login**:
   - URL: `https://localhost:8080`
   - User: `admin`
   - Password: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d`

### Syncing Changes
Any change pushed to the `k8s/` directory in the `main` branch will be automatically detected and synced by ArgoCD within 3 minutes.
