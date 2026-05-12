# Deploying to a Fresh GCP Project

This guide walks you through deploying the complete, production-ready `go-to-production` architecture into an empty Google Cloud project from scratch.

Unlike the migration guide, this assumes you are starting with no existing infrastructure and no legacy data to migrate.

---

## Prerequisites

Ensure you have the following installed locally:
- `gcloud` CLI (authenticated with your Google account)
- `terraform` (>= 1.5)
- `kubectl`
- `docker`
- `cosign` (for container image signing)
- `argocd` CLI

---

## 1. Set Environment Variables

Export these variables in your terminal to make the rest of the commands fully copy-pasteable.

```bash
export PROJECT_ID="your-new-project-id"
export BILLING_ACCOUNT_ID="XXXXXX-XXXXXX-XXXXXX" # Find via: gcloud billing accounts list
export DOMAIN_NAME="todo.yourdomain.com"
export DNS_ZONE="your-dns-zone"
export GITHUB_REPO="your-github-user/go-to-production"
export ALERT_EMAIL="your-email@example.com"
```

---

## 2. Prepare the Repository

The repository uses placeholders. We need to replace them with your actual configuration.

Run these commands in the root of the repository to replace the placeholders globally (the `.bak` extension ensures compatibility across macOS and Linux, and we clean them up afterward):

```bash
# 1. Replace Project ID
grep -rl 'GCP_PROJECT_ID' . --exclude-dir=.git | xargs sed -i.bak "s/GCP_PROJECT_ID/${PROJECT_ID}/g"

# 2. Replace Domain Name
grep -rl 'DOMAIN_NAME' . --exclude-dir=.git | xargs sed -i.bak "s/DOMAIN_NAME/${DOMAIN_NAME}/g"

# 3. Replace DNS Zone
grep -rl 'DNS_ZONE' . --exclude-dir=.git | xargs sed -i.bak "s/DNS_ZONE/${DNS_ZONE}/g"

# Clean up backup files
find . -name "*.bak" -type f -delete
```

---

## 3. Create the GCP Project & Infrastructure

Create the project, link billing, and set up the Terraform state bucket.

```bash
# Create Project and link Billing
gcloud projects create ${PROJECT_ID} --name="Todo App Production"
gcloud billing projects link ${PROJECT_ID} --billing-account=${BILLING_ACCOUNT_ID}
gcloud config set project ${PROJECT_ID}

# Create Terraform State Bucket
gsutil mb -p ${PROJECT_ID} -l us-central1 gs://tf-state-${PROJECT_ID}
gsutil versioning set on gs://tf-state-${PROJECT_ID}
```

Configure and apply Terraform:

```bash
cd terraform

# Create your variables file
cat > terraform.tfvars <<EOF
project_id  = "${PROJECT_ID}"
db_password = "CHANGE_ME_$(openssl rand -hex 12)"
alert_email = "${ALERT_EMAIL}"
EOF

# Initialize and Apply (This takes ~20-40 minutes)
terraform init -backend-config="bucket=tf-state-${PROJECT_ID}"
terraform plan -out=fresh.tfplan
terraform apply fresh.tfplan

# Export the new MCI Ingress IP for DNS setup later
export MCI_IP=$(terraform output -raw mci_static_ip)
cd ..
```

---

## 4. Initialize the Database

Since this is a fresh project, the Cloud SQL database is empty. We need to create the IAM user and the database tables.

```bash
# Get credentials for the primary GKE cluster
gcloud container clusters get-credentials todo-app-cluster \
  --region=us-central1 --project=${PROJECT_ID}

# 1. Create the IAM Database User
kubectl apply -f k8s/base/create-iam-user-job.yaml
kubectl wait --for=condition=complete job/create-iam-user -n todo-app --timeout=120s

# 2. Initialize the Database schema (tables)
kubectl apply -f k8s/base/db-init-job.yaml
kubectl wait --for=condition=complete job/db-init -n todo-app --timeout=120s
```

---

## 5. Build, Sign, and Push the Application Image

Artifact Registry was created by Terraform. Now we build the app and push it.

```bash
# Authenticate Docker to Artifact Registry
gcloud auth configure-docker us-central1-docker.pkg.dev --quiet

export IMAGE="us-central1-docker.pkg.dev/${PROJECT_ID}/todo-app-go/todo-app-go"
export TAG="initial-$(date +%Y%m%d)"

# Build and Push
docker build -t ${IMAGE}:${TAG} .
docker push ${IMAGE}:${TAG}

# Sign the image for Binary Authorization
cosign sign --yes ${IMAGE}:${TAG}
```

Update Kustomize to use this new image digest:

```bash
export DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ${IMAGE}:${TAG} | cut -d@ -f2)

# Update Kustomization file
sed -i.bak "s|digest: sha256:.*|digest: ${DIGEST}|g" k8s/base/kustomization.yaml
rm k8s/base/kustomization.yaml.bak
```

---

## 6. Deploy via ArgoCD (GitOps)

ArgoCD was installed by Terraform. Now we configure it to deploy the application.

```bash
# Get the ArgoCD admin password
export ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Port-forward the ArgoCD UI
kubectl port-forward svc/argocd-server -n argocd 8080:443 > /dev/null 2>&1 &
sleep 3

# Login
argocd login localhost:8080 --insecure --username admin --password ${ARGOCD_PASS}

# Create the application sync
argocd app create todo-app \
  --repo https://github.com/${GITHUB_REPO}.git \
  --revision main \
  --path k8s/ \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace todo-app \
  --sync-policy automated \
  --auto-prune \
  --self-heal

# Kill the port-forward background process
pkill -f "port-forward svc/argocd-server"
```

Verify the app is rolling out:
```bash
kubectl argo rollouts status todo-app-go -n todo-app
```

---

## 7. Setup CI/CD (GitHub Actions + Workload Identity)

To allow GitHub Actions to build and deploy future commits without service account keys, configure Workload Identity Federation (WIF).

```bash
export PROJECT_NUMBER=$(gcloud projects describe ${PROJECT_ID} --format='value(projectNumber)')

# Create WIF Pool
gcloud iam workload-identity-pools create "github" \
  --project=${PROJECT_ID} \
  --location="global" \
  --display-name="GitHub Actions Pool"

# Create OIDC Provider
gcloud iam workload-identity-pools providers create-oidc "github-provider" \
  --project=${PROJECT_ID} \
  --location="global" \
  --workload-identity-pool="github" \
  --display-name="GitHub Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --issuer-uri="https://token.actions.githubusercontent.com"

# Bind the GitHub Actions Deployer SA to the Repository
gcloud iam service-accounts add-iam-policy-binding \
  github-actions-deployer@${PROJECT_ID}.iam.gserviceaccount.com \
  --project=${PROJECT_ID} \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/${GITHUB_REPO}"
```

**Next step:** Go to your GitHub Repository Settings -> Secrets and Variables -> Actions and add:
- `GCP_PROJECT`: Your `${PROJECT_ID}`
- `WIF_PROVIDER`: `projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/providers/github-provider`
- `WIF_SERVICE_ACCOUNT`: `github-actions-deployer@${PROJECT_ID}.iam.gserviceaccount.com`

---

## 8. Finalize DNS

Point your domain to the Multi-Cluster Ingress (MCI) IP address provisioned by Terraform.

```bash
# Print your Ingress IP
echo "Your MCI Ingress IP is: ${MCI_IP}"

# If you use Google Cloud DNS, update it automatically:
gcloud dns record-sets update ${DOMAIN_NAME} \
  --zone=${DNS_ZONE} \
  --type=A \
  --ttl=60 \
  --rrdatas=${MCI_IP}
```

Wait a few minutes for DNS to propagate, then visit `https://${DOMAIN_NAME}/healthz` to verify your fresh deployment!