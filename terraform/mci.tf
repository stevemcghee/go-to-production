# Enable Fleet (GKE Hub) registration for both clusters

# Register Primary Cluster
resource "google_gke_hub_membership" "primary" {
  count         = var.enable_multi_region ? 1 : 0
  membership_id = "primary-cluster-membership"
  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/${google_container_cluster.primary.id}"
    }
  }
  depends_on = [
    google_project_service.gkehub_api,
    google_container_cluster.primary
  ]
}

# Register Secondary Cluster
resource "google_gke_hub_membership" "secondary" {
  count         = var.enable_multi_region ? 1 : 0
  membership_id = "secondary-cluster-membership"
  endpoint {
    gke_cluster {
      resource_link = "//container.googleapis.com/${google_container_cluster.secondary[0].id}"
    }
  }
  depends_on = [
    google_project_service.gkehub_api,
    google_container_cluster.secondary
  ]
}

# Enable Multi-Cluster Ingress Feature on the Fleet
resource "google_gke_hub_feature" "mci" {
  count    = var.enable_multi_region ? 1 : 0
  name     = "multiclusteringress"
  location = "global"
  spec {
    multiclusteringress {
      config_membership = google_gke_hub_membership.primary[0].id
    }
  }
  depends_on = [
    google_project_service.multiclusteringress_api
  ]
}
