resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-rds-subnet-group"
  subnet_ids = var.private_subnet_ids
  tags       = merge(var.tags, { Name = "${var.name}-rds-subnet-group" })
}

resource "aws_db_parameter_group" "postgres15" {
  name   = "${var.name}-postgres15"
  family = "postgres15"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  tags = var.tags
}

resource "aws_db_instance" "this" {
  identifier        = "${var.name}-rds"
  engine            = "postgres"
  engine_version    = "15.4"
  instance_class    = var.instance_class
  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_sg_id]
  parameter_group_name   = aws_db_parameter_group.postgres15.name

  # Single-AZ for cost optimisation (see design trade-offs)
  multi_az            = false
  publicly_accessible = false

  backup_retention_period = 7
  backup_window           = "03:00-04:00"
  maintenance_window      = "Mon:04:00-Mon:05:00"

  # Protect against accidental deletion
  deletion_protection = false  # set true in production
  skip_final_snapshot  = true  # set false in production

  tags = var.tags
}
