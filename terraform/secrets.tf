resource "random_id" "secret_suffix" {
  byte_length = 4
}

resource "random_password" "db_password" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}:?"
}

# Chave aws/secretsmanager gerenciada pela AWS; CMK sem ganho para o escopo.
#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "db_credentials" {
  name        = "${var.project_name}/${var.environment}/db-credentials-${random_id.secret_suffix.hex}"
  description = "Credenciais PostgreSQL — ${var.project_name} ${var.environment}"
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id

  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_password.result
    host     = aws_db_instance.postgres.address
    port     = aws_db_instance.postgres.port
    dbname   = var.db_name
    engine   = "postgres"
  })

  depends_on = [aws_db_instance.postgres]
}
