# Quick Start Deployment (Single Region)

This guide provides a streamlined path to deploy the `go-to-production` application into a single GCP region with minimal configuration.

## Prerequisites

- `gcloud` CLI (authenticated)
- `terraform` (>= 1.5)
- `kubectl`
- `docker`
- `kustomize` (usually bundled with `kubectl`)

## 1. Prepare your GCP Project

Ensure you have a GCP project with billing enabled.

```bash
export PROJECT_ID="your-project-id"
gcloud config set project ${PROJECT_ID}
```

## 2. Run the Quick Deploy Script

The `scripts/quick-deploy.sh` script automates the following:
- Auto-detects your Project ID and User account.
- Replaces project placeholders in the codebase.
- Creates a GCS bucket for Terraform state.
- Provisions a single-region GKE cluster and Cloud SQL instance.
- Initializes the database schema.
- Builds and pushes the application image.
- Deploys the application to GKE.

```bash
./scripts/quick-deploy.sh
```

## 3. Access the Application

Once the script completes, the application will be running. You can check the status:

```bash
kubectl get pods -n todo-app
kubectl get svc -n todo-app
```

Since this quick deployment doesn't require a domain name, it sets up a standard GKE Ingress. Note that the Ingress might take a few minutes to provision a Load Balancer IP.

To find your external IP:
```bash
kubectl get ingress todo-app-ingress -n todo-app
```

## What's Included in Quick Deploy?

- **GKE Autopilot/Standard:** A managed Kubernetes cluster in `us-central1`.
- **Cloud SQL:** A regional PostgreSQL instance with IAM authentication.
- **Artifact Registry:** A private Docker repository.
- **Monitoring & Logging:** Google Cloud Managed Service for Prometheus and Cloud Logging.
- **ArgoCD:** Installed and ready for GitOps (see `docs/DEPLOY_TO_GCP.md` for ArgoCD login details).

## Moving to Multi-Region or Custom Domain

When you are ready to scale or add a domain:
1. Update `terraform/terraform.tfvars` with your domain and set `enable_multi_region = true`.
2. Follow the full guide in [docs/DEPLOY_TO_GCP.md](DEPLOY_TO_GCP.md).
