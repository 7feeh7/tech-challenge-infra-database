variable "aws_region" {
  description = "Regiao AWS."
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Ambiente (homologacao ou producao)."
  type        = string

  validation {
    condition     = contains(["homologacao", "producao"], var.environment)
    error_message = "environment deve ser homologacao ou producao."
  }
}

variable "project_name" {
  description = "Prefixo dos recursos."
  type        = string
  default     = "tech-challenge"
}

variable "db_master_username" {
  description = "Usuario master do RDS (somente administracao; nao e o usuario da aplicacao)."
  type        = string
  default     = "tcadmin"
}

variable "rds_initial_db_name" {
  description = "Database criado na instancia RDS pelo Terraform; databases oficina e billing sao criados pelo Job administrativo."
  type        = string
  default     = "postgres"
}

variable "os_database_name" {
  description = "Nome do database do OS, criado pelo Job administrativo."
  type        = string
  default     = "oficina"
}

variable "billing_database_name" {
  description = "Nome do database do Billing, criado pelo Job administrativo."
  type        = string
  default     = "billing"
}

variable "os_db_username" {
  description = "Usuario PostgreSQL do OS (dono do database oficina)."
  type        = string
  default     = "oficina"
}

variable "billing_db_username" {
  description = "Usuario PostgreSQL do Billing (dono do database billing)."
  type        = string
  default     = "billing"
}

variable "os_connection_limit" {
  description = "CONNECTION LIMIT do usuario do OS (D5.5)."
  type        = number
  default     = 37

  validation {
    condition     = var.os_connection_limit >= 1 && var.os_connection_limit <= 100
    error_message = "os_connection_limit deve estar entre 1 e 100."
  }
}

variable "billing_connection_limit" {
  description = "CONNECTION LIMIT do usuario do Billing (D5.5)."
  type        = number
  default     = 22

  validation {
    condition     = var.billing_connection_limit >= 1 && var.billing_connection_limit <= 100
    error_message = "billing_connection_limit deve estar entre 1 e 100."
  }
}

variable "db_instance_class" {
  description = "Classe da instancia RDS."
  type        = string
  default     = "db.t3.micro"
}

variable "db_allocated_storage" {
  description = "Storage em GB."
  type        = number
  default     = 20
}

variable "db_multi_az" {
  description = "Habilitar Multi-AZ."
  type        = bool
  default     = false
}

variable "db_skip_final_snapshot" {
  description = "Pular snapshot final ao destruir (ignorado em producao, que sempre gera snapshot)."
  type        = bool
  default     = true
}
