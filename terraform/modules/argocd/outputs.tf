output "argocd_metadata" {
  description = "show argocd metadata"
  value       = helm_release.argocd.metadata

}
