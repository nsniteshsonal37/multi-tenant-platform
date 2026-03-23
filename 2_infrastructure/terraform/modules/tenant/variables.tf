variable "tenant_id"           { type = string }
variable "aws_region"          { type = string }
variable "cluster_name"        { type = string }
variable "ecr_registry"        { type = string }
variable "rds_endpoint"        { type = string; sensitive = true }
variable "db_master_username"  { type = string }
variable "db_master_password"  { type = string; sensitive = true }
variable "registry_db_name"    { type = string }
variable "jwt_secret"          { type = string; sensitive = true }
variable "tags"                { type = map(string); default = {} }
