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
