resource "helm_release" "argo_rollouts" {
  name       = "argo-rollouts"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  namespace  = "argo-rollouts"
  create_namespace = true
  version    = "2.35.1" # Recent stable version
}

resource "helm_release" "argo_rollouts_secondary" {
  count      = var.enable_multi_region ? 1 : 0
  provider   = helm.secondary
  name       = "argo-rollouts"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-rollouts"
  namespace  = "argo-rollouts"
  create_namespace = true
  version    = "2.35.1"
}
