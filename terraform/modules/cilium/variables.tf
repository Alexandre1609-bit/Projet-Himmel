variable "pod_cidr" {
  type        = string
  description = "Pod network CIDR, must match kubeadm config"
}

variable "cilium_version" {
  type        = string
  description = "Cilium version to deploy"
  default     = "1.19.1"
}

variable "server_ip" {
  type        = string
  description = "Ip to the main node"
  default     = "192.168.1.50"
}

variable "service_port" {
  type        = string
  description = "Specified service port"
  default     = "6443"
}
