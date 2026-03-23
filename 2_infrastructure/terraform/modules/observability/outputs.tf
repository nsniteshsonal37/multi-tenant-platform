output "otel_grpc_endpoint" {
  value = "http://otel-collector.${kubernetes_namespace.observability.metadata[0].name}.svc.cluster.local:4317"
}
output "otel_http_endpoint" {
  value = "http://otel-collector.${kubernetes_namespace.observability.metadata[0].name}.svc.cluster.local:4318"
}
