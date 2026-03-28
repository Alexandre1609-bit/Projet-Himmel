variable "pod_cidr" {
  type        = string
  description = "Pod network CIDR, must match kubeadm config"
}

variable "cilium_version" {
  type        = string
  description = "configured cilium version"
  default     = "1.19.1"
}
