# terraform/secrets.tf

resource "google_secret_manager_secret" "db_password" {
  secret_id = "db-password"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "db_password_version" {
  secret      = google_secret_manager_secret.db_password.id
  secret_data = var.db_password
}

resource "google_secret_manager_secret" "app_secret" {
  secret_id = "todo-app-secret"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "app_secret_version" {
  secret = google_secret_manager_secret.app_secret.id
  secret_data = jsonencode({
    db_user = replace(google_service_account.todo_app_sa.email, ".gserviceaccount.com", "")
    db_name = var.db_database_name
    db_host = "127.0.0.1"
    db_port = "5432"
  })
}
