variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "eu-central-1"
}

variable "environment" {
  description = "Environment label (production / staging)"
  type        = string
  default     = "production"
}

variable "cluster_name" {
  description = "EKS cluster name (used as prefix for all resources)"
  type        = string
  default     = "hrs-platform"
}

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.29"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.0.0.0/16"
}

# ── Node group ──────────────────────────────────────────────────────────────
variable "node_instance_type" {
  description = "EC2 instance type for EKS managed node group"
  type        = string
  default     = "t3.medium"
}

variable "node_min" {
  description = "Minimum nodes in the managed node group"
  type        = number
  default     = 2
}

variable "node_max" {
  description = "Maximum nodes (Cluster Autoscaler upper bound)"
  type        = number
  default     = 5
}

variable "node_desired" {
  description = "Initial desired node count"
  type        = number
  default     = 2
}

# ── Database ─────────────────────────────────────────────────────────────────
variable "db_name" {
  description = "Initial database name created on the RDS instance"
  type        = string
  default     = "postgres"
}

variable "db_username" {
  description = "RDS master username"
  type        = string
  default     = "dbmaster"
}

variable "db_password" {
  description = "RDS master password (store in AWS Secrets Manager for production)"
  type        = string
  sensitive   = true
}

variable "auth_db_name" {
  description = "PostgreSQL database name for auth-service"
  type        = string
  default     = "auth_db"
}

variable "registry_db_name" {
  description = "PostgreSQL database name for tenant registry (gateway read-only)"
  type        = string
  default     = "registry_db"
}

# ── Application secrets ───────────────────────────────────────────────────────
variable "jwt_secret" {
  description = "JWT signing secret shared between auth-service and gateway"
  type        = string
  sensitive   = true
}

variable "new_relic_license_key" {
  description = "New Relic ingest license key for OTLP export"
  type        = string
  sensitive   = true
}

# ── Ingress / TLS ─────────────────────────────────────────────────────────────
variable "acm_certificate_arn" {
  description = "ARN of an ACM certificate for the shared ALB (must cover domain_name and *.domain_name)"
  type        = string
}

variable "domain_name" {
  description = "Base domain name (e.g. hrs.example.com). API exposed at api.domain_name, Jenkins at jenkins.domain_name"
  type        = string
}

# ── Tenants ───────────────────────────────────────────────────────────────────
variable "tenant_ids" {
  description = "List of tenant IDs to provision. Each gets its own K8s namespace, time-service, database, and registry entry."
  type        = list(string)
  default     = []
}

# ── Jenkins ───────────────────────────────────────────────────────────────────
variable "jenkins_admin_password" {
  description = "Initial Jenkins admin password"
  type        = string
  sensitive   = true
}
