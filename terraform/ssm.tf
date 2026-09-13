resource "aws_ssm_parameter" "rds_endpoint" {
  name  = "${local.ssm_prefix}/database/rds_endpoint"
  type  = "String"
  value = aws_db_instance.postgres.endpoint
}

resource "aws_ssm_parameter" "rds_address" {
  name  = "${local.ssm_prefix}/database/rds_address"
  type  = "String"
  value = aws_db_instance.postgres.address
}

resource "aws_ssm_parameter" "rds_port" {
  name  = "${local.ssm_prefix}/database/rds_port"
  type  = "String"
  value = tostring(aws_db_instance.postgres.port)
}

resource "aws_ssm_parameter" "db_secret_arn" {
  name  = "${local.ssm_prefix}/database/db_secret_arn"
  type  = "String"
  value = aws_secretsmanager_secret.db_credentials.arn
}

resource "aws_ssm_parameter" "db_name" {
  name  = "${local.ssm_prefix}/database/db_name"
  type  = "String"
  value = var.db_name
}

resource "aws_ssm_parameter" "rds_security_group_id" {
  name  = "${local.ssm_prefix}/database/rds_security_group_id"
  type  = "String"
  value = aws_security_group.rds.id
}

resource "aws_ssm_parameter" "db_subnet_group_name" {
  name  = "${local.ssm_prefix}/database/db_subnet_group_name"
  type  = "String"
  value = aws_db_subnet_group.main.name
}
