#!/bin/bash
set -e

PROJECT_ID="${PROJECT_ID:-"YOUR_PROJECT_ID"}"
REGION="us-central1"

echo "Importing resources for project: $PROJECT_ID"

# Enable APIs (these are usually skipped during import but good to have)
# terraform import google_project_service.compute_api $PROJECT_ID/compute.googleapis.com

# GKE Cluster
echo "Importing GKE Cluster..."
terraform import google_container_cluster.primary projects/$PROJECT_ID/locations/$REGION/clusters/todo-app-cluster || true
terraform import google_container_node_pool.primary_nodes projects/$PROJECT_ID/locations/$REGION/clusters/todo-app-cluster/nodePools/todo-app-cluster-node-pool || true

# VPC Network
echo "Importing VPC..."
terraform import google_compute_network.main projects/$PROJECT_ID/global/networks/$PROJECT_ID-vpc || true
terraform import google_compute_subnetwork.private projects/$PROJECT_ID/regions/$REGION/subnetworks/$PROJECT_ID-subnet || true

# Cloud SQL
echo "Importing Cloud SQL..."
terraform import google_sql_database_instance.main_instance projects/$PROJECT_ID/instances/todo-app-db-instance || true
terraform import google_sql_database.database projects/$PROJECT_ID/instances/todo-app-db-instance/databases/todoapp_db || true
terraform import google_sql_user.users projects/$PROJECT_ID/instances/todo-app-db-instance/users/todoappuser || true
# Note: IAM user import might be tricky with the email, trying standard format
terraform import google_sql_user.iam_user projects/$PROJECT_ID/instances/todo-app-db-instance/users/todo-app-sa@$PROJECT_ID.iam.gserviceaccount.com || true

# Read Replica
terraform import google_sql_database_instance.read_replica projects/$PROJECT_ID/instances/todo-app-db-instance-replica || true

# Artifact Registry
echo "Importing Artifact Registry..."
terraform import google_artifact_registry_repository.my-repo projects/$PROJECT_ID/locations/$REGION/repositories/todo-app-go || true

# Service Accounts
echo "Importing Service Accounts..."
terraform import google_service_account.github_actions_deployer projects/$PROJECT_ID/serviceAccounts/github-actions-deployer@$PROJECT_ID.iam.gserviceaccount.com || true
terraform import google_service_account.gke_node projects/$PROJECT_ID/serviceAccounts/gke-node-sa@$PROJECT_ID.iam.gserviceaccount.com || true
terraform import google_service_account.todo_app_sa projects/$PROJECT_ID/serviceAccounts/todo-app-sa@$PROJECT_ID.iam.gserviceaccount.com || true

echo "Import complete. Run 'terraform plan' to verify."
