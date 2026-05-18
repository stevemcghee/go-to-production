# terraform/slos.tf

# Define a service for SLO tracking
# Using GKE cluster service type
resource "google_monitoring_service" "todo_app" {
  service_id   = "todo-app-go-svc"
  display_name = "Todo App Go Service (Primary)"
  
  basic_service {
    service_type = "CLUSTER_ISTIO"
    service_labels = {
      cluster_name      = var.cluster_name
      location          = var.region
      service_namespace = "default"
      service_name      = "todo-app-go"
    }
  }
}

# Service for Secondary Cluster (East)
resource "google_monitoring_service" "todo_app_east" {
  count        = var.enable_multi_region ? 1 : 0
  service_id   = "todo-app-go-east-svc"
  display_name = "Todo App Go Service (Secondary - East)"
  
  basic_service {
    service_type = "CLUSTER_ISTIO"
    service_labels = {
      cluster_name      = "${var.cluster_name}-secondary"
      location          = var.secondary_region
      service_namespace = "default"
      service_name      = "todo-app-go"
    }
  }
}

# Service for Global Load Balancer
resource "google_monitoring_service" "todo_app_global" {
  count        = var.enable_multi_region ? 1 : 0
  service_id   = "todo-app-global-lb"
  display_name = "Todo App Global LB"
  
  basic_service {
    service_type = "CLUSTER_ISTIO"
    service_labels = {
      cluster_name      = "global-lb"
      location          = "global"
      service_namespace = "default"
      service_name      = "todo-app-global"
    }
  }
}

# SLO: Availability (Primary)
resource "google_monitoring_slo" "availability" {
  service      = google_monitoring_service.todo_app.service_id
  slo_id       = "availability-slo"
  display_name = "99.9% Availability SLO (Primary)"

  goal                = 0.999
  rolling_period_days = 28

  request_based_sli {
    good_total_ratio {
      good_service_filter = join(" AND ", [
        "resource.type=\"prometheus_target\"",
        "metric.type=\"prometheus.googleapis.com/http_requests_total/counter\"",
        "resource.labels.cluster=\"${var.cluster_name}\"",
        "metric.labels.code!=\"500\"",
        "metric.labels.code!=\"502\"",
        "metric.labels.code!=\"503\"",
        "metric.labels.code!=\"504\""
      ])

      total_service_filter = join(" AND ", [
        "resource.type=\"prometheus_target\"",
        "metric.type=\"prometheus.googleapis.com/http_requests_total/counter\"",
        "resource.labels.cluster=\"${var.cluster_name}\""
      ])
    }
  }
}

# SLO: Availability (Secondary - East)
resource "google_monitoring_slo" "availability_east" {
  count        = var.enable_multi_region ? 1 : 0
  service      = google_monitoring_service.todo_app_east[0].service_id
  slo_id       = "availability-slo-east"
  display_name = "99.9% Availability SLO (East)"

  goal                = 0.999
  rolling_period_days = 28

  request_based_sli {
    good_total_ratio {
      good_service_filter = join(" AND ", [
        "resource.type=\"prometheus_target\"",
        "metric.type=\"prometheus.googleapis.com/http_requests_total/counter\"",
        "resource.labels.cluster=\"${var.cluster_name}-secondary\"",
        "metric.labels.code!=\"500\"",
        "metric.labels.code!=\"502\"",
        "metric.labels.code!=\"503\"",
        "metric.labels.code!=\"504\""
      ])

      total_service_filter = join(" AND ", [
        "resource.type=\"prometheus_target\"",
        "metric.type=\"prometheus.googleapis.com/http_requests_total/counter\"",
        "resource.labels.cluster=\"${var.cluster_name}-secondary\""
      ])
    }
  }
}

# SLO: Global Availability (Load Balancer)
resource "google_monitoring_slo" "availability_global" {
  count        = var.enable_multi_region ? 1 : 0
  service      = google_monitoring_service.todo_app_global[0].service_id
  slo_id       = "availability-slo-global"
  display_name = "99.99% Global Availability SLO"

  goal                = 0.9999
  rolling_period_days = 28

  request_based_sli {
    good_total_ratio {
      # Good requests: response_code < 500
      good_service_filter = join(" AND ", [
        "resource.type=\"https_lb_rule\"",
        "metric.type=\"loadbalancing.googleapis.com/https/request_count\"",
        "metric.labels.response_code_class!=\"500\""
      ])

      # Total requests
      total_service_filter = join(" AND ", [
        "resource.type=\"https_lb_rule\"",
        "metric.type=\"loadbalancing.googleapis.com/https/request_count\""
      ])
    }
  }
}

# SLO 2: Latency - 95% of requests should complete within 500ms
resource "google_monitoring_slo" "latency" {
  service      = google_monitoring_service.todo_app.service_id
  slo_id       = "latency-slo"
  display_name = "95% requests < 500ms"

  goal                = 0.95   # 95% target
  rolling_period_days = 28     # 28-day rolling window

  request_based_sli {
    distribution_cut {
      distribution_filter = join(" AND ", [
        "resource.type=\"prometheus_target\"",
        "metric.type=\"prometheus.googleapis.com/http_request_duration_seconds/histogram\""
      ])

      range {
        min = 0
        max = 0.5  # 500ms
      }
    }
  }
}

# Alert on fast burn rate (2% budget consumed in 1 hour = incident)
resource "google_monitoring_alert_policy" "availability_fast_burn" {
  display_name = "Availability SLO Fast Burn"
  combiner     = "OR"
  
  conditions {
    display_name = "Availability SLO burning too fast"
    
    condition_threshold {
      # Alert when error budget is being consumed at 10x rate
      # (would exhaust monthly budget in 2.8 days)
      filter = "select_slo_burn_rate(\"${google_monitoring_slo.availability.id}\", 3600s)"
      
      duration   = "0s"
      comparison = "COMPARISON_GT"
      threshold_value = 10
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.name]
  
  alert_strategy {
    auto_close = "604800s"  # 7 days
  }

  documentation {
    content = <<-EOT
      Availability SLO is burning error budget at 10x normal rate.
      
      This means we're consuming the monthly error budget in ~3 days.
      
      **Immediate Actions**:
      1. Check application logs for error spikes
      2. Verify database health
      3. Check circuit breaker state
      4. Review recent deployments
      
      **Context**:
      - SLO Target: 99.9% availability
      - Error Budget: 0.1% of requests can fail
      - Current Burn Rate: 10x normal
    EOT
  }
}

# Alert on slow burn rate (5% budget consumed in 6 hours = warning)
resource "google_monitoring_alert_policy" "availability_slow_burn" {
  display_name = "Availability SLO Slow Burn"
  combiner     = "OR"
  
  conditions {
    display_name = "Availability SLO degrading"
    
    condition_threshold {
      # Alert when error budget is being consumed at 2x rate
      filter = "select_slo_burn_rate(\"${google_monitoring_slo.availability.id}\", 21600s)"
      
      duration   = "0s"
      comparison = "COMPARISON_GT"
      threshold_value = 2
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.name]
  
  alert_strategy {
    auto_close = "604800s"
  }

  documentation {
    content = <<-EOT
      Availability SLO is degrading slowly but consistently.
      
      **Actions**:
      1. Review error trends over past 6 hours
      2. Check for gradual performance degradation
      3. Verify autoscaling is working
      4. Consider proactive intervention before incident
    EOT
  }
}
