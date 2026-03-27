resource "helm_release" "cilium_helm_chart" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"
  values = [yamlencode({
    "ipam.operator.clusterPoolIPv4PodCIDRList" = var.pod_cidr
    kubeProxyReplacement                       = "true"
  })]
  create_namespace = true
}
