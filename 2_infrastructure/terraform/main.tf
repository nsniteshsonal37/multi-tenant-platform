# ── Networking ──────────────────────────────────────────────────────────────
module "vpc" {
  source       = "./modules/vpc"
  name         = var.cluster_name
  aws_region   = var.aws_region
  vpc_cidr     = var.vpc_cidr
  cluster_name = var.cluster_name
  tags         = local.common_tags
}

# ── EKS Cluster ─────────────────────────────────────────────────────────────
module "eks" {
  source             = "./modules/eks"
  cluster_name       = var.cluster_name
  kubernetes_version = var.kubernetes_version
  aws_region         = var.aws_region
  private_subnet_ids = module.vpc.private_subnet_ids
  cluster_sg_id      = module.vpc.cluster_sg_id
  node_sg_id         = module.vpc.node_sg_id
  node_instance_type = var.node_instance_type
  node_min           = var.node_min
  node_max           = var.node_max
  node_desired       = var.node_desired
  tags               = local.common_tags
}

# ── Databases ────────────────────────────────────────────────────────────────
module "rds" {
  source             = "./modules/rds"
  name               = var.cluster_name
  private_subnet_ids = module.vpc.private_subnet_ids
  rds_sg_id          = module.vpc.rds_sg_id
  db_name            = var.db_name
  db_username        = var.db_username
  db_password        = var.db_password
  tags               = local.common_tags
}

# ── Artifact Storage ─────────────────────────────────────────────────────────
module "s3" {
  source       = "./modules/s3"
  name         = var.cluster_name
  aws_region   = var.aws_region
  environment  = var.environment
  tags         = local.common_tags
}

# ── Platform Services (gateway + auth, ESO, ALB controller) ─────────────────
# Depends on EKS being ready. Run `terraform apply -target=module.eks` first.
module "platform" {
  source                 = "./modules/platform"
  cluster_name           = module.eks.cluster_name
  cluster_oidc_issuer    = module.eks.cluster_oidc_issuer
  aws_region             = var.aws_region
  ecr_registry           = module.s3.ecr_registry
  rds_endpoint           = module.rds.endpoint
  db_username            = var.db_username
  db_password            = var.db_password
  auth_db_name           = var.auth_db_name
  registry_db_name       = var.registry_db_name
  jwt_secret             = var.jwt_secret
  new_relic_license_key  = var.new_relic_license_key
  acm_certificate_arn    = var.acm_certificate_arn
  domain_name            = var.domain_name
  node_sg_id             = module.vpc.node_sg_id
  vpc_id                 = module.vpc.vpc_id
  tags                   = local.common_tags

  depends_on = [module.eks, module.rds, module.s3]
}

# ── Tenant Namespaces (one module instance per tenant via for_each) ──────────
module "tenant" {
  source   = "./modules/tenant"
  for_each = toset(var.tenant_ids)

  tenant_id            = each.key
  aws_region           = var.aws_region
  cluster_name         = module.eks.cluster_name
  ecr_registry         = module.s3.ecr_registry
  rds_endpoint         = module.rds.endpoint
  db_master_username   = var.db_username
  db_master_password   = var.db_password
  registry_db_name     = var.registry_db_name
  jwt_secret           = var.jwt_secret
  tags                 = local.common_tags

  depends_on = [module.platform, module.rds]
}

# ── Jenkins CI/CD ─────────────────────────────────────────────────────────────
module "jenkins" {
  source                = "./modules/jenkins"
  aws_region            = var.aws_region
  cluster_name          = module.eks.cluster_name
  cluster_oidc_issuer   = module.eks.cluster_oidc_issuer
  ecr_registry          = module.s3.ecr_registry
  jenkins_admin_password = var.jenkins_admin_password
  acm_certificate_arn   = var.acm_certificate_arn
  domain_name           = var.domain_name
  tags                  = local.common_tags

  depends_on = [module.platform]
}

# ── Observability (OTel Collector → New Relic) ────────────────────────────────
module "observability" {
  source                = "./modules/observability"
  new_relic_license_key = var.new_relic_license_key
  environment           = var.environment
  tags                  = local.common_tags

  depends_on = [module.platform]
}

# ── Database initialisation (runs after RDS + platform are up) ───────────────
# Creates auth_db and registry_db on the shared RDS instance.
# Must run from a host with network access to the RDS private endpoint
# (i.e., from Jenkins inside the cluster, or via VPN/bastion).
resource "null_resource" "init_shared_dbs" {
  triggers = {
    rds_endpoint = module.rds.endpoint
  }

  provisioner "local-exec" {
    command = <<-EOT
      PGPASSWORD='${var.db_password}' psql \
        -h ${module.rds.endpoint} -p 5432 \
        -U ${var.db_username} -d postgres \
        -c "CREATE DATABASE ${var.auth_db_name};" 2>/dev/null || true
      PGPASSWORD='${var.db_password}' psql \
        -h ${module.rds.endpoint} -p 5432 \
        -U ${var.db_username} -d postgres \
        -c "CREATE DATABASE ${var.registry_db_name};" 2>/dev/null || true
    EOT
    environment = {
      PGPASSWORD = var.db_password
    }
  }

  depends_on = [module.rds]
}

locals {
  common_tags = {
    Project     = "hrs-platform"
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}
