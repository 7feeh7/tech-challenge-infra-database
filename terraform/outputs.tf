output "rds_endpoint" {
  description = "Endpoint host:porta do RDS."
  value       = aws_db_instance.postgres.endpoint
}

output "rds_address" {
  description = "Host do RDS."
  value       = aws_db_instance.postgres.address
}

output "db_secret_arn" {
  description = "ARN do secret no Secrets Manager."
  value       = aws_secretsmanager_secret.db_credentials.arn
}

output "ssm_prefix" {
  description = "Prefixo SSM deste ambiente."
  value       = local.ssm_prefix
}
