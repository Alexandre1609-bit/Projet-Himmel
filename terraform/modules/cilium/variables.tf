variable "pod_cidr" {
  type        = string
  description = "Pod network CIDR, must match kubeadm config"
}

variable "cilium_version" {
  type        = string
  description = "Cilium version to deploy"
  default     = "1.19.1"
}
