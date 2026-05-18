resource "null_resource" "argocd_monitoring" {
  # This triggers after the cluster and node pool are ready
  depends_on = [
    google_container_node_pool.primary_nodes,
    helm_release.argocd
  ]

  provisioner "local-exec" {
    command = <<EOT
      gcloud container clusters get-credentials ${var.cluster_name} --region ${var.region} --project ${var.project_id}
      kubectl apply -f ../k8s/base/argocd/pod-monitoring.yaml
    EOT
  }

  # Optional: Ensure it runs again if the file changes
  triggers = {
    manifest_hash = filemd5("${path.module}/../k8s/base/argocd/pod-monitoring.yaml")
  }
}
