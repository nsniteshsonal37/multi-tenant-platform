variable "cluster_name"          { type = string }
variable "cluster_oidc_issuer"   { type = string }
variable "aws_region"            { type = string }
variable "ecr_registry"          { type = string }
variable "rds_endpoint"          { type = string; sensitive = true }
variable "db_username"           { type = string }
variable "db_password"           { type = string; sensitive = true }
variable "auth_db_name"          { type = string }
variable "registry_db_name"      { type = string }
variable "jwt_secret"            { type = string; sensitive = true }
variable "new_relic_license_key" { type = string; sensitive = true }
variable "acm_certificate_arn"   { type = string }
variable "domain_name"           { type = string }
variable "node_sg_id"            { type = string }
variable "vpc_id"                { type = string }
variable "tags"                  { type = map(string); default = {} }
