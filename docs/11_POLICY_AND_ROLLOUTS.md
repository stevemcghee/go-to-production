# Milestone 11: Policy Enforcement & Automated Rollbacks

This document outlines the implementation of policy-as-code using OPA/Gatekeeper and automated, metrics-driven rollouts using Argo Rollouts.

## 1. Checkout this Milestone

To deploy this version of the infrastructure:

```bash
git checkout tags/milestone-11-policy-rollouts
```

## 2. What was Implemented?

We added two critical layers of safety to the production environment.

**Key Features:**
*   **OPA Gatekeeper**: Implemented policy-as-code to enforce organizational standards.
    *   *Constraint Template*: Generic logic to require labels.
    *   *Constraint*: Specifically requiring an `owner` label on all Namespaces.
    *   *Disallow :latest*: Enforces that all images use a specific tag or digest.
    *   *Resource Limits*: Mandatory CPU/Memory limits for all containers.
    *   *Benefit*: Prevents "shadow IT", ensures cost predictability, and enables deterministic rollbacks.
*   **Argo Rollouts**: Replaced standard Deployments with advanced Canary Rollouts.
    *   *Automatic Analysis*: Every deployment triggers a "Smoke Test" job.
    *   *Automated Rollback*: If the smoke test fails (e.g., app returns 500), Argo Rollouts automatically aborts the deployment and rolls back to the stable version.
    *   *Benefit*: Reduces the impact of "broken" code reaching production.
*   **Infrastructure Reliability (GKE Best Practices)**:
    *   **Pod Disruption Budget (PDB)**: Ensures at least one replica is always available during cluster maintenance or node upgrades.
    *   **Backup for GKE**: Re-enabled automated daily backups of the `todo-app` namespace.
    *   **Maintenance Windows**: Defined a daily maintenance window (3 AM UTC) to minimize impact during automated GKE upgrades.

## 3. Pitfalls & Considerations

*   **Policy Friction**: Strict policies can block legitimate developer work. We chose to start with a non-disruptive policy (`owner` label) before moving to stricter security constraints.
*   **Analysis Dependencies**: Analysis jobs (like smoke tests) need to be idempotent and reliable. If the test itself is flaky, it will trigger false-positive rollbacks.
*   **CRD Propagation**: Helm installs for Gatekeeper and Rollouts add many CRDs. Sometimes ArgoCD needs a "Hard Refresh" to recognize these new types.

## 4. Alternatives Considered

*   **Kyverno**: A policy engine designed specifically for Kubernetes.
    *   *Why OPA/Gatekeeper?* OPA is a broader industry standard that uses Rego, allowing for more complex logic that can be shared across other parts of the stack (like Envoy or Terraform).
*   **Cloud Deploy Canary**: We previously used this (Milestone 6).
    *   *Why Argo Rollouts?* Argo Rollouts is native to Kubernetes and provides a much tighter feedback loop with in-cluster metrics and CRDs.

## 5. Usage Instructions

### Violating a Policy
Try creating a namespace without an `owner` label:
```bash
kubectl create ns test-policy
# Expected: Error from server (Forbidden): [ns-must-have-owner] you must provide labels: {"owner"}
```

### Watching a Rollout
When you push a new image tag, watch the canary progress:
```bash
kubectl argo rollouts get rollout todo-app-go -n todo-app --watch
```
