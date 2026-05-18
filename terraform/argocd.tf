resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  version    = "5.51.6" # Recent stable version

  # Set values to configure ArgoCD
  set {
    name  = "server.extraArgs"
    value = "{--insecure}" # Disable TLS on the server pod itself (termination handled by LB/Ingress or just easier for port-forward)
  }

  # Enable Metrics for Monitoring
  set {
    name  = "server.metrics.enabled"
    value = "true"
  }
  set {
    name  = "server.metrics.serviceMonitor.enabled"
    value = "false" # We use PodMonitoring CR for Google Managed Prometheus
  }

  set {
    name  = "repoServer.metrics.enabled"
    value = "true"
  }
  set {
    name  = "repoServer.metrics.serviceMonitor.enabled"
    value = "false"
  }

  set {
    name  = "controller.metrics.enabled"
    value = "true"
  }
  set {
    name  = "controller.metrics.serviceMonitor.enabled"
    value = "false"
  }
  
  # We will rely on port-forwarding to access the UI safely
  # kubectl port-forward svc/argocd-server -n argocd 8080:443
}

# ---------------------------------------------------------------------------------------------------------------------
# REGISTER SECONDARY CLUSTER WITH ARGOCD
# ---------------------------------------------------------------------------------------------------------------------

# 1. Create ServiceAccount in Secondary Cluster
resource "kubernetes_service_account" "argocd_manager_secondary" {
  count    = var.enable_multi_region ? 1 : 0
  provider = kubernetes.secondary
  metadata {
    name      = "argocd-manager"
    namespace = "kube-system"
  }
}

# 2. Bind ServiceAccount to ClusterAdmin in Secondary Cluster
resource "kubernetes_cluster_role_binding" "argocd_manager_secondary" {
  count    = var.enable_multi_region ? 1 : 0
  provider = kubernetes.secondary
  metadata {
    name = "argocd-manager-role-binding"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.argocd_manager_secondary[0].metadata[0].name
    namespace = kubernetes_service_account.argocd_manager_secondary[0].metadata[0].namespace
  }
}

# 3. Create Long-Lived Token for ServiceAccount in Secondary Cluster
resource "kubernetes_secret" "argocd_manager_token_secondary" {
  count    = var.enable_multi_region ? 1 : 0
  provider = kubernetes.secondary
  metadata {
    name      = "argocd-manager-token"
    namespace = "kube-system"
    annotations = {
      "kubernetes.io/service-account.name" = kubernetes_service_account.argocd_manager_secondary[0].metadata[0].name
    }
  }
  type = "kubernetes.io/service-account-token"
}

# 4. Register Secondary Cluster in ArgoCD (Primary Cluster)
resource "kubernetes_secret" "argocd_cluster_secondary" {
  count = var.enable_multi_region ? 1 : 0
  metadata {
    name      = "secondary-cluster-secret"
    namespace = kubernetes_namespace.argocd.metadata[0].name
    labels = {
      "argocd.argoproj.io/secret-type" = "cluster"
    }
  }

  data = {
    name   = "us-east1"
    server = "https://${google_container_cluster.secondary[0].endpoint}"
    config = jsonencode({
      bearerToken = kubernetes_secret.argocd_manager_token_secondary[0].data.token
      tlsClientConfig = {
        insecure = false
        caData   = google_container_cluster.secondary[0].master_auth[0].cluster_ca_certificate
      }
    })
  }
}
