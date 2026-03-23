variable "cluster_name"       { type = string }
variable "kubernetes_version" { type = string }
variable "aws_region"         { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "cluster_sg_id"      { type = string }
variable "node_sg_id"         { type = string }
variable "node_instance_type" { type = string }
variable "node_min"           { type = number }
variable "node_max"           { type = number }
variable "node_desired"       { type = number }
variable "tags"               { type = map(string); default = {} }
