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
