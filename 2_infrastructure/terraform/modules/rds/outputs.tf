output "endpoint" {
  description = "RDS instance connection endpoint (host:port)"
  value       = aws_db_instance.this.endpoint
  sensitive   = true
}

output "address" {
  description = "RDS hostname only (without port)"
  value       = aws_db_instance.this.address
  sensitive   = true
}
