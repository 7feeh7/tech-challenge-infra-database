resource "random_id" "secret_suffix" {
  byte_length = 4
}

# Senhas so com caracteres nao reservados em URL (-_.~): a DATABASE_URL do OS e do Billing
# e montada sem codificacao, e #, ?, %, /, @ e : quebram ou corrompem a URL.
# Os min_* garantem a complexidade que o conjunto menor de especiais nao asseguraria por sorteio.
resource "random_password" "master_db_password" {
  length           = 16
  special          = true
  override_special = "-_.~"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "random_password" "oficina_db_password" {
  length           = 16
  special          = true
  override_special = "-_.~"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

resource "random_password" "billing_db_password" {
  length           = 16
  special          = true
  override_special = "-_.~"
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

# Master: somente Job administrativo (IRSA db-credentials-*).
#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "master_db_credentials" {
  name        = "${var.project_name}/${var.environment}/db-credentials-${random_id.secret_suffix.hex}"
  description = "Credenciais master PostgreSQL — ${var.project_name} ${var.environment}"
}

resource "aws_secretsmanager_secret_version" "master_db_credentials" {
  secret_id = aws_secretsmanager_secret.master_db_credentials.id

  secret_string = jsonencode({
    username = var.db_master_username
    password = random_password.master_db_password.result
    host     = aws_db_instance.postgres.address
    port     = aws_db_instance.postgres.port
    dbname   = var.rds_initial_db_name
    engine   = "postgres"
  })

  depends_on = [aws_db_instance.postgres]
}

#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "oficina_db_user" {
  name        = "${var.project_name}/${var.environment}/db-user-oficina-${random_id.secret_suffix.hex}"
  description = "Usuario de aplicacao do OS (database oficina) — ${var.project_name} ${var.environment}"
}

resource "aws_secretsmanager_secret_version" "oficina_db_user" {
  secret_id = aws_secretsmanager_secret.oficina_db_user.id

  secret_string = jsonencode({
    username = var.os_db_username
    password = random_password.oficina_db_password.result
    host     = aws_db_instance.postgres.address
    port     = aws_db_instance.postgres.port
    dbname   = var.os_database_name
    engine   = "postgres"
  })

  depends_on = [aws_db_instance.postgres]
}

#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "billing_db_user" {
  name        = "${var.project_name}/${var.environment}/db-user-billing-${random_id.secret_suffix.hex}"
  description = "Usuario de aplicacao do Billing (database billing) — ${var.project_name} ${var.environment}"
}

resource "aws_secretsmanager_secret_version" "billing_db_user" {
  secret_id = aws_secretsmanager_secret.billing_db_user.id

  secret_string = jsonencode({
    username = var.billing_db_username
    password = random_password.billing_db_password.result
    host     = aws_db_instance.postgres.address
    port     = aws_db_instance.postgres.port
    dbname   = var.billing_database_name
    engine   = "postgres"
  })

  depends_on = [aws_db_instance.postgres]
}