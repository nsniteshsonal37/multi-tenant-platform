output "artifacts_bucket" { value = aws_s3_bucket.artifacts.bucket }
output "ecr_registry" {
  description = "ECR registry base URL (use as image prefix)"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
}
output "auth_service_repo"    { value = aws_ecr_repository.auth_service.repository_url }
output "gateway_service_repo" { value = aws_ecr_repository.gateway_service.repository_url }
output "time_service_repo"    { value = aws_ecr_repository.time_service.repository_url }
