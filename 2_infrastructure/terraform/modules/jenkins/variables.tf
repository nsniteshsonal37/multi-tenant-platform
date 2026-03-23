variable "aws_region"             { type = string }
variable "cluster_name"           { type = string }
variable "cluster_oidc_issuer"    { type = string }
variable "ecr_registry"           { type = string }
variable "jenkins_admin_password" { type = string; sensitive = true }
variable "acm_certificate_arn"    { type = string }
variable "domain_name"            { type = string }
variable "tags"                   { type = map(string); default = {} }
