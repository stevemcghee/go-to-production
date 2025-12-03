resource "google_monitoring_notification_channel" "email" {
  display_name = "Email Notification Channel"
  type         = "email"
  labels = {
    email_address = var.alert_email
  }
}

resource "google_monitoring_alert_policy" "high_error_rate" {
  display_name = "High Error Rate (HTTP 5xx)"
  combiner     = "OR"
  conditions {
    display_name = "HTTP 5xx > 1%"
    condition_threshold {
      filter     = "resource.type=\"prometheus_target\" AND metric.type=\"prometheus.googleapis.com/http_requests_total/counter\" AND metric.labels.code = monitoring.regex.full_match(\"5..\")"
      duration   = "300s"
      comparison = "COMPARISON_GT"
      aggregations {
        alignment_period     = "60s"
        per_series_aligner   = "ALIGN_RATE"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["resource.cluster", "resource.namespace"]
      }
      threshold_value = 0.01
    }
  }
  notification_channels = [google_monitoring_notification_channel.email.name]
}
