resource "google_gke_backup_backup_plan" "todo_app_backup" {
  name     = "todo-app-backup"
  cluster  = google_container_cluster.primary.id
  location = var.region

  retention_policy {
    backup_retain_days = 7
  }

  backup_schedule {
    cron_schedule = "0 2 * * *" # 2 AM UTC
  }

  backup_config {
    include_secrets     = true
    include_volume_data = true
    selected_namespaces {
      namespaces = ["todo-app"]
    }
  }

  depends_on = [google_project_service.gkebackup_api]
}

# GCS bucket for backup exports with retention policy to prevent deletion
resource "google_storage_bucket" "backups" {
  name          = "${var.project_id}-db-backups"
  location      = var.region
  project       = var.project_id
  force_destroy = false

  versioning {
    enabled = true
  }

  retention_policy {
    retention_period = 2592000 # 30 days in seconds
    is_locked        = false   # Lock after validating in production
  }

  lifecycle_rule {
    condition {
      age = 90 # Clean up old versions after 90 days
    }
    action {
      type = "Delete"
    }
  }
}
