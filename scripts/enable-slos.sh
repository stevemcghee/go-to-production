#!/bin/bash
set -e

# --- Configuration ---
PROJECT_ID=$(gcloud config get-value project 2>/dev/null)
REGION=$(grep "region" terraform/terraform.tfvars | cut -d'=' -f2 | tr -d ' "' || echo "us-central1")

echo "--- Enabling SLOs and Load Generation for go-to-production ---"
echo "Project: $PROJECT_ID"
echo "Region:  $REGION"
echo "------------------------------------------------------------"

if [ -z "$PROJECT_ID" ]; then
  echo "Error: No GCP project detected."
  exit 1
fi

# 1. Update Terraform to enable SLO resources
echo "Updating terraform.tfvars..."
if grep -q "enable_slos" terraform/terraform.tfvars; then
  sed -i.bak 's/enable_slos *= *false/enable_slos = true/' terraform/terraform.tfvars
else
  echo 'enable_slos = true' >> terraform/terraform.tfvars
fi
rm -f terraform/terraform.tfvars.bak

# 2. Apply Terraform changes
echo "Applying Terraform (this adds google_monitoring_service and google_monitoring_slo)..."
cd terraform
terraform apply -auto-approve
cd ..

# 3. Ensure Load Generator is running in Kubernetes
echo "Ensuring load generator is active..."
gcloud container clusters get-credentials todo-app-cluster --region=${REGION} --project=${PROJECT_ID}
kubectl apply -f k8s/base/load-generator.yaml -n todo-app

# 4. Get LB IP for verification
LB_IP=$(kubectl get ingress todo-app-ingress -n todo-app -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

echo "--------------------------------------------"
echo "SLOs and Load Generation Enabled!"
echo ""
echo "Load Generator: Running every minute via CronJob"
echo "Monitoring:     SLOs are being created in Cloud Monitoring"
echo "Service URL:    http://${LB_IP} (if Load Balancer is ready)"
echo ""
echo "Next Steps:"
echo "1. Wait 5-10 minutes for metrics to populate."
echo "2. Visit the Cloud Monitoring Dashboards in the GCP Console."
echo "3. Check the 'Services & SLOs' tab in Cloud Monitoring."
echo "--------------------------------------------"
