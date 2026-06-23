resource "helm_release" "cilium_helm_chart" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = var.cilium_version
  namespace  = "kube-system"

  set = [{
    name  = "hubble.enabled"
    value = "true"
    },
    {
      name  = "hubble.metrics.enabled"
      value = "{dns,drop,tcp,flow,port_distribution,icmp,httpV2:exemplars=true;labelsContext=source_ip,source_namespace,destination_ip,destination_namespace,destination_workload,traffic_direction}"
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
      name  = "operator.prometheus.enabled"
      value = "true"
    },
    {
      name  = "prometheus.enabled"
      value = "true"
    },
    {
      name  = "prometheus.port"
      value = "9962"
    },
    {
      name  = "gatewayAPI.enabled"
      value = "true"
    },
    {
      name  = "l2announcements.enabled"
      value = "true"
    },
    {
      name  = "l2announcements.leaseDuration"
      value = "3s"
    },
    {
      name  = "l2announcements.leaseRenewDeadline"
      value = "1s"
    },
    {
      name  = "l2announcements.leaseRetryPeriod"
      value = "500ms"
    },
    {
      name  = "devices"
      value = "eno1"
    },
    {
      name  = "externalIPs.enabled"
      value = "true"
    },
    {
      name  = "k8sClientRateLimit.qps"
      value = "50"
    },
    {
      name  = "k8sClientRateLimit.burst"
      value = "100"
    },
    {
      name  = "kubeProxyReplacement"
      value = "true"
    },
    {
      name  = "k8sServiceHost"
      value = var.server_ip
    },
    {
      name  = "k8sServicePort"
      value = var.service_port
    },
  ]
}
