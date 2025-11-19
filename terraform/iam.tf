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
