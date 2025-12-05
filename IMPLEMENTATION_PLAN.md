# Implementation Plan for Production Readiness

This document outlines the branching strategy and step-by-step implementation plan for making the `todo-app-go` application a production-ready, resilient, and secure service.

The strategy is to use a series of feature branches, where each branch represents a major architectural evolution of the system. This allows for clear, incremental progress that can be reviewed and merged via pull requests.

---

### 1. Branch: `feature/gke-base-deployment`

*   **Goal:** Get the application running on a basic GKE cluster with a managed database. This is the foundational step to move away from the local Docker environment.
*   **Tasks:**
    1.  Update Terraform scripts to provision a basic GKE cluster and a single-zone Cloud SQL instance.
    2.  Create the initial Kubernetes manifests (`deployment.yaml`, `service.yaml`) for the todo-app.
    3.  Update the GitHub Actions CI/CD pipeline to:
        *   Build and publish the Docker image to Google Artifact Registry.
        *   Authenticate to GKE and apply the Kubernetes manifests.
*   **Risks Addressed:** This branch lays the groundwork but doesn't fully mitigate the major risks yet. It serves as a "walking skeleton" for the production environment.

---

### 2. Branch: `feature/ha-scalability-hardening` (Branches from `feature/gke-base-deployment`)

*   **Goal:** Make the base deployment highly available, scalable, and secure.
*   **Tasks:**
    1.  Upgrade the GKE cluster in Terraform to be a *regional* cluster (spanning multiple zones).
    2.  Upgrade the Cloud SQL instance in Terraform to use the High Availability (HA) configuration.
    3.  Implement a Horizontal Pod Autoscaler (HPA) in Kubernetes to automatically scale the application.
    4.  Implement Workload Identity and use Secret Manager for database credentials, removing them from environment variables.
    5.  Update the Go application to fetch credentials from Secret Manager.
*   **Risks Addressed:**
    *   ✅ Single Point of Failure (Application & Database)
    *   ✅ Lack of Scalability
    *   ✅ Zonal Failure
    *   ✅ Insecure and Inflexible Configuration

---

### 3. Branch: `feature/security-and-observability` (Branches from `feature/ha-scalability-hardening`)

*   **Goal:** Protect the application from external threats and improve monitoring.
*   **Tasks:**
    1.  Use Terraform to provision a Google Cloud Load Balancer with Google Cloud Armor (WAF) to protect against DDoS and other attacks.
    2.  Implement a Content Security Policy (CSP) in the `index.html` template.
    3.  Integrate a security scanner (like `gosec` or `Trivy`) into the CI/CD pipeline.
*   **Risks Addressed:**
    *   ✅ DDoS attacks or other security concerns

---

### 4. Branch: `feature/disaster-recovery-multi-region` (Branches from `feature/ha-scalability-hardening`)

*   **Goal:** Prepare for a full regional outage. This is a more advanced, parallel track to the security work.
*   **Tasks:**
    1.  Update Terraform to be able to replicate the entire GKE and Cloud SQL setup in a second region.
    2.  Configure the Cloud Load Balancer to manage traffic between the two regions, failing over if one region becomes unhealthy.
    3.  Configure cross-region replication for the Cloud SQL instance.
*   **Risks Addressed:**
    *   ✅ Compute Service or Regional Failure within GCP
