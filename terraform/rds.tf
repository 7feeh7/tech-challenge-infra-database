resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-${var.environment}-db-subnet"
  subnet_ids = local.private_subnet_ids

  tags = {
    Name = "${var.project_name}-${var.environment}-db-subnet"
  }
}

# deletion_protection e ligado em producao via condicional (tfsec nao resolve).
# Performance Insights nao suportado em db.t3.micro.
#tfsec:ignore:aws-rds-enable-performance-insights
resource "aws_db_instance" "postgres" {
  identifier     = "${var.project_name}-${var.environment}-db"
  engine         = "postgres"
  engine_version = "16"

  instance_class    = var.db_instance_class
  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_password.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  iam_database_authentication_enabled = true

  backup_retention_period = var.environment == "producao" ? 7 : 0
  deletion_protection     = var.environment == "producao" #tfsec:ignore:AVD-AWS-0177
  skip_final_snapshot     = var.db_skip_final_snapshot

  tags = {
    Name = "${var.project_name}-${var.environment}-db"
  }
}
