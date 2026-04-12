
provider "kubernetes" {
  config_path = "~/.kube/config" #Config k8s locale

}

provider "helm" {
  kubernetes = {
    config_path = "~/.kube/config"
  }
}

module "cilium" {
  source         = "./modules/cilium"
  pod_cidr       = var.pod_cidr
  cilium_version = var.cilium_version
}


module "argocd" {
  source              = "./modules/argocd"
  server_service_type = var.server_service_type
  argocd_version      = var.argocd_version
}
