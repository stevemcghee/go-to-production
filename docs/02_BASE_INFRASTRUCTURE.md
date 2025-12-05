# Milestone 2: Base Infrastructure (Walking Skeleton)

This document outlines the deployment of the "Walking Skeleton" - the minimum viable infrastructure to get the app running in the cloud.

## 1. Checkout this Milestone

To deploy this version of the infrastructure:

```bash
git checkout tags/milestone-base-infra
```

## 2. What was Implemented?

We moved from local Docker Compose to a cloud-native setup on Google Cloud.

**Key Features:**
*   **GKE Cluster (Zonal)**: A single-zone Kubernetes cluster.
    *   *Benefit*: Managed container orchestration.
*   **Cloud SQL (Single Zone)**: Managed PostgreSQL instance.
    *   *Benefit*: No need to manage database backups or OS patching.
*   **CI/CD Pipeline**: GitHub Actions to build and deploy.
    *   *Benefit*: Automated, repeatable deployments.

## 3. Pitfalls & Considerations

*   **Zonal Failures**: This architecture is **NOT** high availability. If the zone `us-central1-a` goes down, the app goes down.
*   **Database Passwords**: At this stage, we are still handling database passwords via Terraform outputs and manual secrets. This is a security risk addressed in Milestone 4.
*   **Public IP**: The Cloud SQL instance has a public IP (though protected by the proxy). Private Service Connect would be more secure but more complex to set up initially.

## 4. Alternatives Considered

*   **Cloud Run**: Simpler and cheaper for this specific app.
    *   *Why GKE?* To demonstrate Kubernetes patterns (Sidecars, HPA, Workload Identity) relevant to larger scale systems.
*   **GKE Autopilot**: Would simplify node management.
    *   *Why Standard?* To show explicit control over node pools and resources for educational purposes.

## Deployment Instructions

(Original instructions follow...)


Before running `terraform apply`, ensure the Google Cloud user you are authenticated as has the **`Editor`** role on the GCP project. This is a one-time bootstrap step that must be done manually.

```bash
# Example command to grant the role
gcloud projects add-iam-policy-binding your-gcp-project-id \
  --member="user:your-email@example.com" \
  --role="roles/editor"
```

---

### **Prerequisite 2: Default Compute Engine Service Account**

Ensure the default Compute Engine service account is enabled in your project. This is a hard requirement for GKE cluster creation. You have confirmed this step is complete.

---

### Step 1: Run `terraform apply`

Once the prerequisites are met, execute `terraform apply` in the `terraform/` directory.

This command will provision:
*   A GKE cluster.
*   A Cloud SQL for PostgreSQL instance.
*   The necessary Service Accounts and IAM roles for GKE nodes and the CI/CD pipeline.

```bash
cd terraform/
terraform init
terraform apply
```
After `apply` is complete, Terraform will output several values, including the **`cloudsql_instance_connection_name`** and the **`github_actions_deployer_email`**. You will need these for the next steps.

---

### Step 2: Create a Service Account Key

Using the service account email from the Terraform output, generate a JSON key file for the CI/CD service account.

```bash
# Retrieve the email from Terraform output
export SA_EMAIL=$(terraform output -raw github_actions_deployer_email)

# Generate the key file
gcloud iam service-accounts keys create "gcp-sa-key.json" \
  --iam-account="$SA_EMAIL"
```
This creates a file named `gcp-sa-key.json` in your current directory.

---

### Step 3: Configure GitHub Secrets and Variables

Configure the following in your GitHub repository's settings (`Settings > Secrets and variables > Actions`).

#### GitHub Secrets
*   **`GCP_SA_KEY`**:
    *   **Value:** The **entire content** of the `gcp-sa-key.json` file.
    *   **Purpose:** Allows GitHub Actions to authenticate with Google Cloud.

#### GitHub Variables
*   **`GCP_PROJECT_ID`**:
    *   **Value:** Your Google Cloud Project ID.
*   **`GCR_HOSTNAME`**:
    *   **Value:** The hostname for Google Artifact Registry (e.g., `us-central1-docker.pkg.dev`).
*   **`GKE_CLUSTER_NAME`**:
    *   **Value:** The name of your GKE cluster (default: `todo-app-cluster`).
*   **`GKE_CLUSTER_LOCATION`**:
    *   **Value:** The zone where your GKE cluster is located (default: `us-central1-a`).
*   **`GKE_SQL_INSTANCE_CONNECTION_NAME`**:
    *   **Value:** The **`cloudsql_instance_connection_name`** value from the `terraform output`.
    *   **Purpose:** Tells the Cloud SQL Auth Proxy in the GKE pod which database instance to connect to.

---

### How the Cloud SQL Auth Proxy Works

*   The Cloud SQL instance has a public IP, but is configured to **reject all public traffic**.
*   A **Cloud SQL Auth Proxy** container runs as a "sidecar" alongside the application in the GKE pod.
*   This proxy uses secure IAM authentication to connect to the database.
*   The application connects to the proxy on `localhost:5432`, so it never needs to know the database's real IP address. This is a secure and standard architecture.
