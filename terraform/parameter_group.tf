resource "aws_db_parameter_group" "postgres16" {
  name   = "${var.project_name}-${var.environment}-pg16"
  family = "postgres16"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_statement"
    value = "ddl"
  }

  # O master do RDS nao tem permissao de SET neste parametro; a sessao de senha do Job exige 0 e so
  # dispensa o SET quando o valor ja vem do parameter group.
  parameter {
    name  = "log_parameter_max_length"
    value = "0"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-pg16"
  }
}
