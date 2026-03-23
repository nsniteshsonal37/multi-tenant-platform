data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

# ── S3 — Artifact Storage ─────────────────────────────────────────────────────
resource "aws_s3_bucket" "artifacts" {
  bucket        = "${var.name}-artifacts-${local.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id

  rule {
    id     = "expire-old-artifacts"
    status = "Enabled"

    filter { prefix = "" }

    expiration { days = 90 }

    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── ECR — Container Registries ────────────────────────────────────────────────
resource "aws_ecr_repository" "auth_service" {
  name                 = "${var.name}/auth-service"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration { scan_on_push = true }

  tags = var.tags
}

resource "aws_ecr_repository" "gateway_service" {
  name                 = "${var.name}/gateway-service"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration { scan_on_push = true }

  tags = var.tags
}

resource "aws_ecr_repository" "time_service" {
  name                 = "${var.name}/time-service"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration { scan_on_push = true }

  tags = var.tags
}

# Lifecycle: keep last 10 tagged images, remove untagged after 1 day
resource "aws_ecr_lifecycle_policy" "services" {
  for_each   = {
    auth    = aws_ecr_repository.auth_service.name
    gateway = aws_ecr_repository.gateway_service.name
    time    = aws_ecr_repository.time_service.name
  }
  repository = each.value

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Remove untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep last 10 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "sha-"]
          countType     = "imageCountMoreThan"
          countNumber   = 10
        }
        action = { type = "expire" }
      }
    ]
  })
}
