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
grep -rl 'irtco-sandbox' . --exclude-dir=.git --exclude='scripts/quick-deploy.sh' | xargs -r sed -i.bak "s/irtco-sandbox/${PROJECT_ID}/g"
# Also replace 'go-to-production' project ID in K8s configs if they slipped through
grep -rl 'go-to-production' k8s/ --exclude-dir=.git | xargs -r sed -i.bak "s/go-to-production/${PROJECT_ID}/g"
# We don't replace todo-irtco-sandbox.example.com here yet; single-region quick-deploy will use IP/Service LoadBalancer if needed, 
# but the existing K8s configs use Ingress. We'll leave them for now or provide instructions.
# Quick fix for ManagedCertificate validation error:
grep -rl 'todo-irtco-sandbox.example.com' . --exclude-dir=.git --exclude='scripts/quick-deploy.sh' | xargs -r sed -i.bak "s/todo-irtco-sandbox.example.com/todo-${PROJECT_ID}.example.com/g"
# Remove multi-cluster-service from kustomization since MCI is disabled
sed -i.bak '/- multi-cluster-service.yaml/d' k8s/base/kustomization.yaml
# Remove the read-replica connection string from the Cloud SQL proxy since it doesn't exist
sed -i.bak '/- ".*todo-app-db-instance-replica?port=5433"/d' k8s/base/rollouts/todo-app-rollout.yaml
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
enable_l7_lb                = true
enable_binary_authorization = false
enable_slos                 = false
EOF

echo "Initializing Terraform..."
terraform init -backend-config="bucket=tf-state-${PROJECT_ID}" -reconfigure

echo "Applying Terraform (this may take 15-20 minutes)..."
terraform apply -auto-approve

echo "Waiting 30 seconds for IAM bindings (Workload Identity) to propagate..."
sleep 30

# --- 3. Database & App Deployment ---
echo "Setting up kubectl context..."
gcloud container clusters get-credentials todo-app-cluster --region=${REGION} --project=${PROJECT_ID}

echo "Creating Kubernetes secrets..."
# Create the namespace first so we can put the secret in it
kubectl apply -f ../k8s/base/namespace.yaml
kubectl create secret generic db-credentials \
  --namespace=todo-app \
  --from-literal=username=todoappuser \
  --from-literal=password=$DB_PASSWORD \
  --from-literal=dbname=todoapp_db \
  --dry-run=client -o yaml | kubectl apply -f -

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
# We run apply twice with a short delay to handle OPA Gatekeeper CRD generation race conditions.
kubectl apply -k k8s/base || { echo "Waiting for Gatekeeper CRDs to register..."; sleep 10; kubectl apply -k k8s/base; }

echo "--------------------------------------------"
echo "Deployment Complete!"
echo "Check your services: kubectl get svc -n todo-app"
echo "Database Password (stored in terraform/terraform.tfvars): $DB_PASSWORD"
echo "--------------------------------------------"
