# terraform/iam.tf

# Service Account for GitHub Actions CI/CD
resource "google_service_account" "github_actions_deployer" {
  account_id   = "github-actions-deployer"
  display_name = "GitHub Actions Deployer SA"
  project      = var.project_id
}

# Grant the Artifact Registry Writer role to the Service Account
resource "google_project_iam_member" "artifact_writer" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github_actions_deployer.email}"
}

# Grant the Kubernetes Engine Developer role to the Service Account
resource "google_project_iam_member" "gke_developer" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.github_actions_deployer.email}"
}

# Grant the Cloud Deploy Releaser role to the Service Account
resource "google_project_iam_member" "cloud_deploy_releaser" {
  project = var.project_id
  role    = "roles/clouddeploy.releaser"
  member  = "serviceAccount:${google_service_account.github_actions_deployer.email}"
}

# Grant the Cloud Deploy Job Runner role to the Service Account
resource "google_project_iam_member" "cloud_deploy_job_runner" {
  project = var.project_id
  role    = "roles/clouddeploy.jobRunner"
  member  = "serviceAccount:${google_service_account.github_actions_deployer.email}"
}

# Grant the Storage Admin role to the Service Account (required by google-github-actions/create-cloud-deploy-release)
resource "google_project_iam_member" "storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.github_actions_deployer.email}"
}

# Grant the Service Account User role to the Service Account
resource "google_project_iam_member" "service_account_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.github_actions_deployer.email}"
}

# Service Account for GKE Nodes
resource "google_service_account" "gke_node" {
  account_id   = "gke-node-sa"
  display_name = "GKE Node Service Account"
  project      = var.project_id
}

# Grant necessary roles for GKE nodes
resource "google_project_iam_member" "gke_node_monitoring_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_project_iam_member" "gke_node_logging_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_project_iam_member" "gke_node_artifact_reader" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

resource "google_project_iam_member" "gke_node_sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

# --- Workload Identity Configuration ---

# Service Account for Application (Workload Identity)
resource "google_service_account" "todo_app_sa" {
  account_id   = "todo-app-sa"
  display_name = "Todo App Service Account"
  project      = var.project_id
}

# Grant Secret Accessor role to the Application Service Account
resource "google_project_iam_member" "secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.todo_app_sa.email}"
}

# Grant Cloud SQL Client role to the Application Service Account (for Auth Proxy)
resource "google_project_iam_member" "sql_client" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.todo_app_sa.email}"
}

# Grant Cloud SQL Instance User role for IAM authentication
resource "google_project_iam_member" "sql_instance_user" {
  project = var.project_id
  role    = "roles/cloudsql.instanceUser"
  member  = "serviceAccount:${google_service_account.todo_app_sa.email}"
}

# Grant Cloud Trace Agent role for writing traces
resource "google_project_iam_member" "trace_agent" {
  project = var.project_id
  role    = "roles/cloudtrace.agent"
  member  = "serviceAccount:${google_service_account.todo_app_sa.email}"
}

# Bind the Kubernetes Service Account to the Google Service Account
resource "google_service_account_iam_member" "workload_identity_binding" {
  service_account_id = google_service_account.todo_app_sa.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[todo-app/todo-app-sa]"
}
