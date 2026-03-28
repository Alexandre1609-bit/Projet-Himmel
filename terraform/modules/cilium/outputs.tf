output "cilium_metadata" {
  description = "Show cilium metadata"
  value       = helm_release.cilium_helm_chart.metadata
}
