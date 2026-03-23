output "namespace"         { value = kubernetes_namespace.tenant.metadata[0].name }
output "time_service_dns"  {
  description = "Internal K8s DNS name for the time-service (used by gateway)"
  value       = "http://time-service.${kubernetes_namespace.tenant.metadata[0].name}.svc.cluster.local:8080"
}
