#!/bin/bash
set -e

# --- Configuration & Defaults ---
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION="us-central1"
DB_PASSWORD=$(openssl rand -hex 12)
GITHUB_REPO=$(git remote get-url origin 2>/dev/null | sed -E 's|.*github.com[:/](.*).git|\1|' || echo "YOUR_GITHUB_REPO")
ALERT_EMAIL=$(gcloud config get-value account 2>/dev/null || echo "YOUR_EMAIL@example.com")

echo "--- Quick Deployment for go-to-production ---"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "Repo:    $GITHUB_REPO"
echo "Email:   $ALERT_EMAIL"
echo "--------------------------------------------"

if [ -z "$PROJECT_ID" ]; then
  echo "Error: No GCP project detected. Run 'gcloud config set project [PROJECT_ID]' first."
  exit 1
fi

# --- 1. Prepare the Repository (Placeholder Replacement) ---
echo "Replacing placeholders in repository..."
grep -rl 'GCP_PROJECT_ID' . --exclude-dir=.git --exclude='scripts/quick-deploy.sh' | xargs sed -i.bak "s/GCP_PROJECT_ID/${PROJECT_ID}/g"
# We don't replace DOMAIN_NAME here yet; single-region quick-deploy will use IP/Service LoadBalancer if needed, 
# but the existing K8s configs use Ingress. We'll leave them for now or provide instructions.
# Quick fix for ManagedCertificate validation error:
grep -rl 'DOMAIN_NAME' . --exclude-dir=.git --exclude='scripts/quick-deploy.sh' | xargs sed -i.bak "s/DOMAIN_NAME/todo-${PROJECT_ID}.example.com/g"
# Remove multi-cluster-service from kustomization since MCI is disabled
sed -i.bak '/- multi-cluster-service.yaml/d' k8s/base/kustomization.yaml
find . -name "*.bak" -type f -delete

# --- 2. Infrastructure Setup (Terraform) ---
echo "Creating Terraform State Bucket (if it doesn't exist)..."
gsutil mb -p ${PROJECT_ID} -l ${REGION} gs://tf-state-${PROJECT_ID} 2>/dev/null || echo "Bucket already exists."
gsutil versioning set on gs://tf-state-${PROJECT_ID}

cd terraform
cat > terraform.tfvars <<EOF
project_id                  = "${PROJECT_ID}"
db_password                 = "${DB_PASSWORD}"
alert_email                 = "${ALERT_EMAIL}"
enable_multi_region         = false
enable_binary_authorization = false
enable_slos                 = false
EOF

echo "Initializing Terraform..."
terraform init -backend-config="bucket=tf-state-${PROJECT_ID}" -reconfigure

echo "Applying Terraform (this may take 15-20 minutes)..."
terraform apply -auto-approve

# --- 3. Database & App Deployment ---
echo "Setting up kubectl context..."
gcloud container clusters get-credentials todo-app-cluster --region=${REGION} --project=${PROJECT_ID}

echo "Initializing Database..."
kubectl apply -f ../k8s/base/create-iam-user-job.yaml
kubectl apply -f ../k8s/base/db-init-job.yaml

echo "Building and Pushing initial Docker image..."
gcloud auth configure-docker ${REGION}-docker.pkg.dev --quiet
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/todo-app-go/todo-app-go"
TAG="v1-$(date +%Y%m%d-%H%M)"
docker build -t ${IMAGE}:${TAG} ..
docker push ${IMAGE}:${TAG}

# Update Kustomization with the new image
cd ../k8s/base
# Remove any existing image configuration for todo-app-go to avoid conflicts with digests
sed -i.bak '/- name: todo-app-go/,/digest:/d' kustomization.yaml
rm kustomization.yaml.bak
kustomize edit set image todo-app-go=${IMAGE}:${TAG}
cd ../..

echo "Deploying to GKE..."
# For quick-deploy, we apply directly. ArgoCD is also installed and can be used later.
kubectl apply -k k8s/base

echo "--------------------------------------------"
echo "Deployment Complete!"
echo "Check your services: kubectl get svc -n todo-app"
echo "Database Password (stored in terraform/terraform.tfvars): $DB_PASSWORD"
echo "--------------------------------------------"
