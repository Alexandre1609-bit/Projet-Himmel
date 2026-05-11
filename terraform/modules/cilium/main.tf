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
    "hubble.metrics.enabled"                   = "dns,drop,tcp,flow,port_distribution,icmp,httpV2:exemplars=true;labelsContext=source_ip,source_namespace,destination_ip,destination_namespace,destination_workload,traffic_direction}"
  })]
  create_namespace = true

  set = [{
    name  = "hubble.enabled"
    value = "true"
    },
    {
      name  = "hubble.relay.enabled"
      value = "true"
    },
    {
      name  = "hubble.ui.enabled"
      value = "true"
    },
    {
      name  = "hubble.ui.service.type"
      value = "NodePort"
    },
    {
      name  = "hubble.ui.service.nodePort"
      value = "30082"
    },
    {
      name  = "prometheus.enabled"
      value = "true"
    },
    {
      name  = "prometheus.port"
      value = "9962"
    }
  ]
}
