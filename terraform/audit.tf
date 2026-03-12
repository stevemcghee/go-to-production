# Enable Data Access audit logs for Cloud SQL and GKE
resource "google_project_iam_audit_config" "cloudsql" {
  project = var.project_id
  service = "cloudsql.googleapis.com"
  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

resource "google_project_iam_audit_config" "gke" {
  project = var.project_id
  service = "container.googleapis.com"
  audit_log_config {
    log_type = "ADMIN_READ"
  }
  audit_log_config {
    log_type = "DATA_READ"
  }
  audit_log_config {
    log_type = "DATA_WRITE"
  }
}

# BigQuery dataset for long-term audit log retention
resource "google_bigquery_dataset" "audit_logs" {
  dataset_id    = "audit_logs"
  friendly_name = "Audit Logs"
  description   = "Long-term storage for admin activity and data access audit logs"
  location      = var.region
  project       = var.project_id

  default_table_expiration_ms = 365 * 24 * 60 * 60 * 1000 # 1 year
}

# Log sink for admin activity to BigQuery
resource "google_logging_project_sink" "admin_activity" {
  name        = "admin-activity-to-bigquery"
  project     = var.project_id
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.audit_logs.dataset_id}"
  filter      = "logName:\"logs/cloudaudit.googleapis.com%2Factivity\""

  unique_writer_identity = true

  bigquery_options {
    use_partitioned_tables = true
  }
}

# Grant the sink's writer identity access to the BigQuery dataset
resource "google_bigquery_dataset_iam_member" "audit_sink_writer" {
  project    = var.project_id
  dataset_id = google_bigquery_dataset.audit_logs.dataset_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.admin_activity.writer_identity
}

# Alert on IAM policy changes
resource "google_monitoring_alert_policy" "iam_changes" {
  display_name = "IAM Policy Changes Detected"
  combiner     = "OR"
  conditions {
    display_name = "SetIamPolicy called"
    condition_matched_log {
      filter = "protoPayload.methodName=\"SetIamPolicy\""
    }
  }
  notification_channels = [google_monitoring_notification_channel.email.name]

  alert_strategy {
    notification_rate_limit {
      period = "300s"
    }
  }
}
