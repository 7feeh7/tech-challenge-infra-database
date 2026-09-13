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

variable "db_name" {
  description = "Nome do banco PostgreSQL."
  type        = string
  default     = "oficina"
}

variable "db_username" {
  description = "Usuario master do RDS."
  type        = string
  default     = "oficina"
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
