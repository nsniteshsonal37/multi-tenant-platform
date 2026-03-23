output "platform_namespace"      { value = kubernetes_namespace.platform.metadata[0].name }
output "gateway_service_name"    { value = kubernetes_service.gateway_service.metadata[0].name }
output "auth_service_name"       { value = kubernetes_service.auth_service.metadata[0].name }
output "eso_role_arn"            { value = aws_iam_role.eso.arn }
output "lbc_role_arn"            { value = aws_iam_role.lbc.arn }
