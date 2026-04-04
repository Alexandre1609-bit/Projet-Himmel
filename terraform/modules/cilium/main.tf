resource "helm_release" "cilium_helm_chart" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"
  values = [yamlencode({
    "ipam.operator.clusterPoolIPv4PodCIDRList" = var.pod_cidr
    kubeProxyReplacement                       = "true"
    "k8sServiceHost"                           = "192.168.1.50"
    "k8sServicePort"                           = "6443"
  })]
  create_namespace = true
}
