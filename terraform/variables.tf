variable "pod_cidr" {
  type        = string
  description = "Pod network CIDR, must match kubeadm config"
}

variable "cilium_version" {
  type        = string
  description = "configured cilium version"
  default     = "1.19.1"
}


variable "argocd_version" {
  type        = string
  description = "argocd version"
  default     = "3.3.6"
}

variable "server_service_type" {
  type        = string
  description = "choose between NodePort & LoadBalancer"
  default     = "NodePort"
}
