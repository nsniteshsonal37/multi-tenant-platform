output "cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "ecr_registry" {
  description = "ECR registry URL (account.dkr.ecr.region.amazonaws.com)"
  value       = module.s3.ecr_registry
}

output "rds_endpoint" {
  description = "RDS instance endpoint"
  value       = module.rds.endpoint
  sensitive   = true
}

output "tenant_ids" {
  description = "Currently provisioned tenant IDs (used by Jenkins tenant-provision pipeline)"
  value       = var.tenant_ids
}

output "alb_dns_name" {
  description = "DNS name of the shared Application Load Balancer"
  value       = "Check AWS console → EC2 → Load Balancers → filter by tag Project=hrs-platform"
}
