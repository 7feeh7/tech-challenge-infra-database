#!/usr/bin/env bash
# Provisiona databases e usuarios no RDS. Senhas e verificadores nunca vao para stdout/stderr, argumento
# de linha de comando, arquivo ou log do PostgreSQL.
set -euo pipefail

SCRIPTS_DIR="/scripts"
WORK_DIR="${WORK_DIR:-/tmp/db-admin-work}"
# Primeira versao do psql cuja libpq gera o verificador SCRAM-SHA-256 no cliente (PQencryptPasswordConn).
MIN_PSQL_MAJOR_VERSION=10

log() {
  printf '%s\n' "$*" >&2
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    log "Variavel obrigatoria ausente ou vazia: ${name}"
    exit 1
  fi
}

for v in AWS_REGION MASTER_SECRET_ARN OFICINA_USER_SECRET_ARN BILLING_USER_SECRET_ARN \
  OS_DB_USERNAME BILLING_DB_USERNAME OS_DATABASE_NAME BILLING_DATABASE_NAME \
  OS_CONNECTION_LIMIT BILLING_CONNECTION_LIMIT; do
  require_env "$v"
done

mkdir -p "$WORK_DIR"

install_if_missing() {
  if ! command -v "$1" >/dev/null 2>&1; then
    log "Instalando dependencia: $1..."
    if ! yum install -y -q "$2" >/dev/null 2>&1; then
      log "Falha ao instalar pacote ${2} (binario ${1})."
      exit 1
    fi
  fi
}

if ! command -v psql >/dev/null 2>&1; then
  log "Instalando cliente PostgreSQL (extras postgresql14)..."
  if ! amazon-linux-extras install -y postgresql14 >/dev/null 2>&1; then
    install_if_missing psql postgresql
  fi
fi

# O pacote generico do yum pode trazer um psql antigo, cujo \password gera hash MD5 em vez de SCRAM.
psql_major_version="$(psql --version | grep -oE '[0-9]+' | head -n 1)"
if (( psql_major_version < MIN_PSQL_MAJOR_VERSION )); then
  log "Cliente psql ${psql_major_version} nao gera verificador SCRAM-SHA-256 (minimo: ${MIN_PSQL_MAJOR_VERSION})."
  exit 1
fi

install_if_missing jq jq
install_if_missing envsubst gettext

fetch_secret_field() {
  local arn="$1"
  local field="$2"
  aws secretsmanager get-secret-value \
    --secret-id "$arn" \
    --region "$AWS_REGION" \
    --query SecretString \
    --output text \
    | jq -r --arg f "$field" '.[$f] // empty'
}

MASTER_USER="$(fetch_secret_field "$MASTER_SECRET_ARN" username)"
MASTER_PASS="$(fetch_secret_field "$MASTER_SECRET_ARN" password)"
MASTER_HOST="$(fetch_secret_field "$MASTER_SECRET_ARN" host)"
MASTER_PORT="$(fetch_secret_field "$MASTER_SECRET_ARN" port)"
MASTER_DB="$(fetch_secret_field "$MASTER_SECRET_ARN" dbname)"

OFICINA_PASS="$(fetch_secret_field "$OFICINA_USER_SECRET_ARN" password)"
BILLING_PASS="$(fetch_secret_field "$BILLING_USER_SECRET_ARN" password)"

for v in MASTER_USER MASTER_PASS MASTER_HOST MASTER_PORT MASTER_DB OFICINA_PASS BILLING_PASS; do
  if [[ -z "${!v}" ]]; then
    log "Campo obrigatorio ausente ou vazio no Secrets Manager (identificador interno: ${v})."
    exit 1
  fi
done

# O \password le a senha linha a linha da entrada padrao: quebra de linha no valor gravaria outra senha.
for v in OFICINA_PASS BILLING_PASS; do
  if [[ "${!v}" == *$'\n'* || "${!v}" == *$'\r'* ]]; then
    log "Senha com quebra de linha no Secrets Manager (identificador interno: ${v})."
    exit 1
  fi
done

# A senha do master fica so no ambiente de cada psql, nunca exportada para os demais processos.
run_psql() {
  PGPASSWORD="$MASTER_PASS" psql -v ON_ERROR_STOP=1 \
    -h "$MASTER_HOST" -p "$MASTER_PORT" -U "$MASTER_USER" -d "$MASTER_DB" "$@"
}

create_role_with_password() {
  local role="$1"
  local password="$2"
  if ! printf '%s\n%s\n' "$password" "$password" \
    | run_psql -q -v role="$role" -f "${SCRIPTS_DIR}/create-role-with-password.sql"; then
    log "Falha ao criar o papel ${role} com senha; nenhuma senha foi gravada para ele."
    exit 1
  fi
}

run_sql() {
  local sql_file="${WORK_DIR}/provision.runtime.sql"
  envsubst '$OS_DB_USERNAME $BILLING_DB_USERNAME $OS_DATABASE_NAME $BILLING_DATABASE_NAME $OS_CONNECTION_LIMIT $BILLING_CONNECTION_LIMIT' \
    <"${SCRIPTS_DIR}/provision.sql.tpl" >"$sql_file"
  run_psql -q -f "$sql_file"
  rm -f "$sql_file"
}

export OS_DB_USERNAME BILLING_DB_USERNAME OS_DATABASE_NAME BILLING_DATABASE_NAME
export OS_CONNECTION_LIMIT BILLING_CONNECTION_LIMIT

log "Criando papeis com senha em sessao sem registro de comandos (sem exibir credenciais)..."
create_role_with_password "$OS_DB_USERNAME" "$OFICINA_PASS"
create_role_with_password "$BILLING_DB_USERNAME" "$BILLING_PASS"

log "Aplicando SQL administrativo (sem exibir credenciais)..."
run_sql

MAX_CONN="$(run_psql -tAc 'SHOW max_connections' | tr -d '[:space:]')"
log "Provisionamento concluido. max_connections=${MAX_CONN}"
