# main.tf

terraform {
  required_providers {
    google = {
      source = "hashicorp/google"
    }
  }
}

# Configure the Google Cloud provider
provider "google" {
  project = var.project_id
  region  = var.region
}

# Enable necessary Google Cloud APIs
resource "google_project_service" "compute_api" {
  project = var.project_id
  service = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "container_api" {
  project = var.project_id
  service = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "sqladmin_api" {
  project = var.project_id
  service = "sqladmin.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudresourcemanager_api" {
  project = var.project_id
  service = "cloudresourcemanager.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam_api" {
  project = var.project_id
  service = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "artifactregistry_api" {
  project = var.project_id
  service = "artifactregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "logging_api" {
  project = var.project_id
  service = "logging.googleapis.com"
  disable_on_destroy = false
}

# Create a GKE cluster
resource "google_container_cluster" "primary" {
  name                     = var.cluster_name
  location                 = var.zone
  remove_default_node_pool = true
  initial_node_count       = 1 # A default node pool is required if remove_default_node_pool is true, but we're removing it so we set this to 1

  network    = google_compute_network.main.name
  subnetwork = google_compute_subnetwork.private.name

  ip_allocation_policy {
    cluster_ipv4_cidr_block = "/19"
    services_ipv4_cidr_block = "/22"
  }

  # Enable Cloud Logging for container logs
  logging_service = "logging.googleapis.com/kubernetes"
  logging_config {
    enable_components = ["SYSTEM_COMPONENTS", "WORKLOADS"]
  }

  # Enable Cloud Monitoring
  monitoring_service = "monitoring.googleapis.com/kubernetes"
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = true
    }
  }

  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }
}

# Create a GKE node pool
resource "google_container_node_pool" "primary_nodes" {
  name       = "${google_container_cluster.primary.name}-node-pool"
  location   = var.zone
  cluster    = google_container_cluster.primary.name
  node_count = 2

  node_config {
    machine_type = "e2-medium"
    service_account = google_service_account.gke_node.email
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform"
    ]
    metadata = {
      disable-legacy-endpoints = "true"
    }
  }
}

# Create a custom VPC network
resource "google_compute_network" "main" {
  name                    = "${var.project_id}-vpc"
  auto_create_subnetworks = false
}

# Create a private subnetwork for the GKE cluster
resource "google_compute_subnetwork" "private" {
  name          = "${var.project_id}-subnet"
  ip_cidr_range = "10.0.0.0/20"
  region        = var.region
  network       = google_compute_network.main.name
}

# Create a Cloud SQL instance
resource "google_sql_database_instance" "main_instance" {
  name             = var.db_instance_name
  database_version = "POSTGRES_14"
  region           = var.region

  settings {
    tier = "db-f1-micro" # Smallest tier for testing/dev
    availability_type = "ZONAL"
    ip_configuration {
      ipv4_enabled = true
    }
    backup_configuration {
      enabled            = true
      start_time         = "03:00"
    }
    maintenance_window {
      day  = 7
      hour = 3
    }
  }
}

# Create a database within the Cloud SQL instance
resource "google_sql_database" "database" {
  name       = var.db_database_name
  instance   = google_sql_database_instance.main_instance.name
  charset    = "UTF8"
  collation  = "en_US.UTF8"
}

# Create a user for the database
resource "google_sql_user" "users" {
  name     = var.db_user
  instance = google_sql_database_instance.main_instance.name
  password = var.db_password
}

# Create Artifact Registry Repository
resource "google_artifact_registry_repository" "my-repo" {
  location      = var.region
  repository_id = "todo-app-go"
  description   = "Docker repository for todo-app-go"
  format        = "DOCKER"
}

