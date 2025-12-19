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
  
  # We will rely on port-forwarding to access the UI safely
  # kubectl port-forward svc/argocd-server -n argocd 8080:443
}
