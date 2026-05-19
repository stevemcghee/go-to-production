# terraform/dashboard.tf

resource "google_monitoring_dashboard" "todo_app_overview" {
  count = var.enable_slos ? 1 : 0
  
  dashboard_json = jsonencode({
    displayName = "Todo App - System Overview"
    
    mosaicLayout = {
      columns = 12
      
      tiles = [
        # ===== ROW 1: SLO STATUS =====
        {
          width  = 12
          height = 2
          xPos   = 0
          yPos   = 0
          widget = {
            title = "SLO Overview"
            text = {
              content = "**Availability SLO**: 99.9% over 28 days | **Latency SLO**: 95% < 500ms\\n\\nMonitor burn rate alerts for SLO violations. Fast burn (10x) requires immediate action. Slow burn (2x) requires investigation."
              format = "MARKDOWN"
            }
          }
        },
        {
          width  = 12
          height = 4
          xPos   = 0
          yPos   = 2
          widget = {
            title = "SLO Burn Rate (1 hour window)"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = "select_slo_burn_rate(\"${google_monitoring_slo.availability[0].id}\", 3600s)"
                      aggregation = {
                        alignmentPeriod  = "60s"
                        perSeriesAligner = "ALIGN_MEAN"
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                }
              ]
              yAxis = {
                label = "Burn Rate"
                scale = "LINEAR"
              }
              thresholds = [
                {
                  value = 1.0
                },
                {
                  value = 2.0
                },
                {
                  value = 10.0
                }
              ]
            }
          }
        },
        
        # ===== ROW 2: REQUEST METRICS =====
        {
          width  = 12
          height = 4
          xPos   = 0
          yPos   = 6
          widget = {
            title = "Request Rate (req/s)"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"prometheus_target\"",
                        "metric.type=\"prometheus.googleapis.com/http_requests_total/counter\""
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_RATE"
                        crossSeriesReducer = "REDUCE_SUM"
                        groupByFields      = ["metric.label.path"]
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                }
              ]
              yAxis = {
                label = "Requests/sec"
                scale = "LINEAR"
              }
            }
          }
        },
        
        # ===== ROW 3: ERROR RATE & LATENCY =====
        {
          width  = 6
          height = 4
          xPos   = 0
          yPos   = 10
          widget = {
            title = "Error Rate (5xx responses)"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"prometheus_target\"",
                        "metric.type=\"prometheus.googleapis.com/http_requests_total/counter\"",
                        "metric.labels.code=monitoring.regex.full_match(\"5..\")"
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_RATE"
                        crossSeriesReducer = "REDUCE_SUM"
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                }
              ]
              yAxis = {
                label = "Errors/sec"
                scale = "LINEAR"
              }
              thresholds = [
                {
                  value = 0.01
                }
              ]
            }
          }
        },
        {
          width  = 6
          height = 4
          xPos   = 6
          yPos   = 10
          widget = {
            title = "Request Latency (Average)"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"prometheus_target\"",
                        "metric.type=\"prometheus.googleapis.com/http_request_duration_seconds/histogram\""
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_DELTA"
                        crossSeriesReducer = "REDUCE_MEAN"
                        groupByFields      = ["metric.label.path"]
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                }
              ]
              yAxis = {
                label = "Seconds"
                scale = "LINEAR"
              }
              thresholds = [
                {
                  value = 0.5
                }
              ]
            }
          }
        },
        
        # ===== ROW 4: BUSINESS METRICS =====
        {
          width  = 12
          height = 4
          xPos   = 0
          yPos   = 14
          widget = {
            title = "Todo Operations (Business Metrics)"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"prometheus_target\"",
                        "metric.type=\"prometheus.googleapis.com/todos_added_total/counter\""
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_RATE"
                        crossSeriesReducer = "REDUCE_SUM"
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                  legendTemplate = "Added"
                },
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"prometheus_target\"",
                        "metric.type=\"prometheus.googleapis.com/todos_updated_total/counter\""
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_RATE"
                        crossSeriesReducer = "REDUCE_SUM"
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                  legendTemplate = "Updated"
                },
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"prometheus_target\"",
                        "metric.type=\"prometheus.googleapis.com/todos_deleted_total/counter\""
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_RATE"
                        crossSeriesReducer = "REDUCE_SUM"
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                  legendTemplate = "Deleted"
                }
              ]
              yAxis = {
                label = "Ops/sec"
                scale = "LINEAR"
              }
            }
          }
        },
        
        # ===== ROW 5: INFRASTRUCTURE - PODS & DATABASE =====
        {
          width  = 3
          height = 4
          xPos   = 0
          yPos   = 18
          widget = {
            title = "Active Pods"
            scorecard = {
              timeSeriesQuery = {
                timeSeriesFilter = {
                  filter = join(" AND ", [
                    "resource.type=\"k8s_container\"",
                    "metric.type=\"kubernetes.io/container/uptime\"",
                    "resource.labels.pod_name=monitoring.regex.full_match(\"todo-app-go-.*\")",
                    "resource.labels.namespace_name=\"todo-app\"",
                    "resource.labels.container_name=\"todo-app-go\""
                  ])
                  aggregation = {
                    alignmentPeriod    = "60s"
                    perSeriesAligner   = "ALIGN_MEAN"
                    crossSeriesReducer = "REDUCE_COUNT"
                  }
                }
              }
              sparkChartView = {
                sparkChartType = "SPARK_BAR"
              }
            }
          }
        },
        {
          width  = 3
          height = 4
          xPos   = 3
          yPos   = 18
          widget = {
            title = "Cloud SQL - CPU Utilization"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"cloudsql_database\"",
                        "metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\""
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_MEAN"
                        crossSeriesReducer = "REDUCE_MEAN"
                        groupByFields      = ["resource.label.database_id"]
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                }
              ]
              yAxis = {
                label = "CPU %"
                scale = "LINEAR"
              }
              thresholds = [
                {
                  value = 0.8
                },
                {
                  value = 0.9
                }
              ]
            }
          }
        },
        {
          width  = 3
          height = 4
          xPos   = 6
          yPos   = 18
          widget = {
            title = "Cloud SQL - Active Connections"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"cloudsql_database\"",
                        "metric.type=\"cloudsql.googleapis.com/database/postgresql/num_backends\""
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_MEAN"
                        crossSeriesReducer = "REDUCE_MEAN"
                        groupByFields      = ["resource.label.database_id"]
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                }
              ]
              yAxis = {
                label = "Connections"
                scale = "LINEAR"
              }
            }
          }
        },
        {
          width  = 3
          height = 4
          xPos   = 9
          yPos   = 18
          widget = {
            title = "Cloud SQL - Replication Lag"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"cloudsql_database\"",
                        "metric.type=\"cloudsql.googleapis.com/database/replication/replica_lag\""
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_MEAN"
                        crossSeriesReducer = "REDUCE_MEAN"
                        groupByFields      = ["resource.label.database_id"]
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                }
              ]
              yAxis = {
                label = "Lag (Seconds)"
                scale = "LINEAR"
              }
            }
          }
        },
        
        # ===== ROW 6: ROLLOUT PROGRESS =====
        {
          width  = 8
          height = 4
          xPos   = 0
          yPos   = 22
          widget = {
            title = "Rollout Progress (Pods per Cluster)"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"k8s_container\"",
                        "metric.type=\"kubernetes.io/container/uptime\"",
                        "resource.labels.pod_name=monitoring.regex.full_match(\"todo-app-go-.*\")",
                        "resource.labels.namespace_name=\"todo-app\""
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_MEAN"
                        crossSeriesReducer = "REDUCE_COUNT"
                        groupByFields      = ["resource.label.cluster_name"]
                      }
                    }
                  }
                  plotType   = "STACKED_AREA"
                  targetAxis = "Y1"
                }
              ]
              yAxis = {
                label = "Pod Count"
                scale = "LINEAR"
              }
            }
          }
        },
        {
          width  = 4
          height = 4
          xPos   = 8
          yPos   = 22
          widget = {
            title = "Active Revisions (Timeline)"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      aggregation = {
                        alignmentPeriod    = "60s"
                        crossSeriesReducer = "REDUCE_MAX"
                        groupByFields      = [
                          "metric.label.revision",
                          "metric.label.name",
                        ]
                        perSeriesAligner   = "ALIGN_MAX"
                      }
                      filter      = "resource.type=\"prometheus_target\" AND metric.type=\"prometheus.googleapis.com/argocd_app_info/gauge\" AND metric.labels.name=monitoring.regex.full_match(\"todo-app.*\")"
                    }
                  }
                  plotType       = "STACKED_AREA"
                  targetAxis     = "Y1"
                  legendTemplate = "App: $${metric.label.name} | Rev: $${metric.label.revision}"
                }
              ]
              yAxis    = {
                label = "Active"
                scale = "LINEAR"
              }
            }
          }
        },

        # ===== ROW 7: GKE NODE HEALTH =====
        {
          width  = 6
          height = 4
          xPos   = 0
          yPos   = 26
          widget = {
            title = "GKE Node CPU Utilization"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"k8s_node\"",
                        "metric.type=\"kubernetes.io/node/cpu/allocatable_utilization\""
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_MEAN"
                        crossSeriesReducer = "REDUCE_MEAN"
                        groupByFields      = ["resource.label.node_name"]
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                }
              ]
              yAxis = {
                label = "CPU %"
                scale = "LINEAR"
              }
              thresholds = [
                {
                  value = 0.8
                },
                {
                  value = 0.9
                }
              ]
            }
          }
        },
        {
          width  = 6
          height = 4
          xPos   = 6
          yPos   = 26
          widget = {
            title = "GKE Node Memory Utilization"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"k8s_node\"",
                        "metric.type=\"kubernetes.io/node/memory/allocatable_utilization\""
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_MEAN"
                        crossSeriesReducer = "REDUCE_MEAN"
                        groupByFields      = ["resource.label.node_name"]
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                }
              ]
              yAxis = {
                label = "Memory %"
                scale = "LINEAR"
              }
              thresholds = [
                {
                  value = 0.8
                },
                {
                  value = 0.9
                }
              ]
            }
          }
        },
        # ===== ROW 8: ARGOCD STATUS =====
        {
          width  = 12
          height = 4
          xPos   = 0
          yPos   = 30
          widget = {
            title = "ArgoCD Application Health"
            xyChart = {
              dataSets = [
                {
                  timeSeriesQuery = {
                    timeSeriesFilter = {
                      filter = join(" AND ", [
                        "resource.type=\"prometheus_target\"",
                        "metric.type=\"prometheus.googleapis.com/argocd_app_info/gauge\""
                      ])
                      aggregation = {
                        alignmentPeriod    = "60s"
                        perSeriesAligner   = "ALIGN_MEAN"
                        crossSeriesReducer = "REDUCE_COUNT"
                        groupByFields      = ["metric.label.health_status"]
                      }
                    }
                  }
                  plotType   = "LINE"
                  targetAxis = "Y1"
                }
              ]
              yAxis = {
                label = "App Count"
                scale = "LINEAR"
              }
            }
          }
        }
      ]
    }
  })
}

# Output the dashboard URL
output "dashboard_url" {
  description = "URL to the custom monitoring dashboard"
  value       = var.enable_slos ? "https://console.cloud.google.com/monitoring/dashboards/custom/${google_monitoring_dashboard.todo_app_overview[0].id}?project=${var.project_id}" : ""
}
