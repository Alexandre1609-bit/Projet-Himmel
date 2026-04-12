resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_version
  namespace  = "argocd"
  values = [yamlencode({
    "server.service.type" = var.server_service_type
  })]
  create_namespace = true


}
