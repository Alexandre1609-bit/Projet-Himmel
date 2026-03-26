
provider "kubernetes" {
  config_path = "~/.kube/config" #Config k8s locale

}

provider "helm" {
  kubernetes = {
    config_path = "~/.kube/config"
  }
}



#Pour cilium plus tard
# module "cilium" {
#    source = "./modules/cilium"
#}
