variable "name"         { type = string }
variable "aws_region"   { type = string }
variable "vpc_cidr"     { type = string }
variable "cluster_name" { type = string }
variable "tags"         { type = map(string); default = {} }
