variable "new_relic_license_key" { type = string; sensitive = true }
variable "environment"           { type = string }
variable "tags"                  { type = map(string); default = {} }
