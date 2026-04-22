variable "argocd_version" {
  type        = string
  description = "argocd version"
  default     = "9.5.4"
}

variable "server_service_type" {
  type        = string
  description = "choose between NodePort & LoadBalancer"
  default     = "NodePort"
}
