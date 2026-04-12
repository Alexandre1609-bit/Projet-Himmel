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
