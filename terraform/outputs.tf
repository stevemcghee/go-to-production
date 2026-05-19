# outputs.tf

output "kubeconfig" {
  description = "Kubernetes config file for connecting to the GKE cluster"
  value       = google_container_cluster.primary.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "cluster_name" {
  description = "The name of the GKE cluster"
  value       = google_container_cluster.primary.name
}

output "region" {
  description = "The region where the cluster is located"
  value       = google_container_cluster.primary.location
}

output "cloudsql_instance_connection_name" {
  description = "The connection name of the Cloud SQL instance"
  value       = google_sql_database_instance.main_instance.connection_name
}

output "github_actions_deployer_email" {
  description = "The email address of the service account for GitHub Actions"
  value       = google_service_account.github_actions_deployer.email
}
output "cloudsql_replica_connection_name" {
  description = "The connection name of the Cloud SQL Read Replica"
  value       = var.enable_multi_region ? google_sql_database_instance.read_replica[0].connection_name : ""
}

output "secondary_kubeconfig" {
  description = "Kubernetes config file for connecting to the secondary GKE cluster"
  value       = var.enable_multi_region ? google_container_cluster.secondary[0].master_auth[0].cluster_ca_certificate : ""
  sensitive   = true
}

output "secondary_cluster_name" {
  description = "The name of the secondary GKE cluster"
  value       = var.enable_multi_region ? google_container_cluster.secondary[0].name : ""
}

output "secondary_region" {
  description = "The region where the secondary cluster is located"
  value       = var.enable_multi_region ? google_container_cluster.secondary[0].location : ""
}

output "lb_static_ip" {
  description = "The static global IP for the L7 Load Balancer"
  value       = (var.enable_multi_region || var.enable_l7_lb) ? google_compute_global_address.todo_app_ip[0].address : ""
}
