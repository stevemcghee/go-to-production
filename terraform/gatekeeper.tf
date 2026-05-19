resource "helm_release" "gatekeeper" {
  name       = "gatekeeper"
  repository = "https://open-policy-agent.github.io/gatekeeper/charts"
  chart      = "gatekeeper"
  namespace  = "gatekeeper-system"
  create_namespace = true
  version    = "3.14.0" # Recent stable version

  set {
    name  = "replicas"
    value = "2"
  }
}

resource "helm_release" "gatekeeper_secondary" {
  count      = var.enable_multi_region ? 1 : 0
  provider   = helm.secondary
  name       = "gatekeeper"
  repository = "https://open-policy-agent.github.io/gatekeeper/charts"
  chart      = "gatekeeper"
  namespace  = "gatekeeper-system"
  create_namespace = true
  version    = "3.14.0"
  wait       = false
  skip_crds  = true

  set {
    name  = "replicas"
    value = "2"
  }
}
