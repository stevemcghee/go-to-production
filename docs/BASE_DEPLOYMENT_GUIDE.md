# HOWTO: Manual Steps for `feature/gke-base-deployment`

This document outlines manual steps required after running `terraform apply` for the `feature/gke-base-deployment` branch.

---

### **Prerequisite 1: GCP User Permissions**

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
