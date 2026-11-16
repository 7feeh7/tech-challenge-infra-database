#!/usr/bin/env bash
# Provisiona databases e usuarios no RDS. Senhas nunca vao para stdout/stderr.
set -euo pipefail

WORK_DIR="${WORK_DIR:-/tmp/db-admin-work}"

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
    yum install -y -q "$2" >/dev/null
  fi
}

install_if_missing psql postgresql15
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

export PGPASSWORD="$MASTER_PASS"
PSQL=(psql -v ON_ERROR_STOP=1 -h "$MASTER_HOST" -p "$MASTER_PORT" -U "$MASTER_USER" -d "$MASTER_DB")

role_exists() {
  local role="$1"
  local found
  found="$("${PSQL[@]}" -tAc "SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = '${role}'" | tr -d '[:space:]')"
  [[ "$found" == "1" ]]
}

escape_sql_literal() {
  local value="$1"
  printf "%s" "$value" | sed "s/'/''/g"
}

apply_role_password() {
  local role="$1"
  local pass="$2"
  local escaped_pass
  local sql_file="${WORK_DIR}/set_password_${role}.sql"
  escaped_pass="$(escape_sql_literal "$pass")"
  printf 'ALTER ROLE "%s" PASSWORD '\''%s'\'';\n' "$role" "$escaped_pass" >"$sql_file"
  "${PSQL[@]}" -q -f "$sql_file"
  rm -f "$sql_file"
}

run_sql() {
  local sql_file="${WORK_DIR}/provision.runtime.sql"
  envsubst '$OS_DB_USERNAME $BILLING_DB_USERNAME $OS_DATABASE_NAME $BILLING_DATABASE_NAME $OS_CONNECTION_LIMIT $BILLING_CONNECTION_LIMIT' \
    </scripts/provision.sql.tpl >"$sql_file"
  "${PSQL[@]}" -q -f "$sql_file"
  rm -f "$sql_file"
}

export OS_DB_USERNAME BILLING_DB_USERNAME OS_DATABASE_NAME BILLING_DATABASE_NAME
export OS_CONNECTION_LIMIT BILLING_CONNECTION_LIMIT

OFICINA_EXISTIA=false
BILLING_EXISTIA=false
if role_exists "$OS_DB_USERNAME"; then
  OFICINA_EXISTIA=true
fi
if role_exists "$BILLING_DB_USERNAME"; then
  BILLING_EXISTIA=true
fi

log "Aplicando SQL administrativo (sem exibir credenciais)..."
run_sql

if ! $OFICINA_EXISTIA && role_exists "$OS_DB_USERNAME"; then
  apply_role_password "$OS_DB_USERNAME" "$OFICINA_PASS"
fi
if ! $BILLING_EXISTIA && role_exists "$BILLING_DB_USERNAME"; then
  apply_role_password "$BILLING_DB_USERNAME" "$BILLING_PASS"
fi

MAX_CONN="$("${PSQL[@]}" -tAc 'SHOW max_connections' | tr -d '[:space:]')"
log "Provisionamento concluido. max_connections=${MAX_CONN}"