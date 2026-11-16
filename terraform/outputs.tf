output "rds_endpoint" {
  description = "Endpoint host:porta do RDS."
  value       = aws_db_instance.postgres.endpoint
}

output "rds_address" {
  description = "Host do RDS."
  value       = aws_db_instance.postgres.address
}

output "db_secret_arn" {
  description = "ARN do segredo do usuario do OS (db-user-oficina)."
  value       = aws_secretsmanager_secret.oficina_db_user.arn
}

output "billing_db_secret_arn" {
  description = "ARN do segredo do usuario do Billing (db-user-billing)."
  value       = aws_secretsmanager_secret.billing_db_user.arn
}

output "ssm_prefix" {
  description = "Prefixo SSM deste ambiente."
  value       = local.ssm_prefix
}
