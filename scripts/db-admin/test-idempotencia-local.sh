#!/usr/bin/env bash
# Testa idempotencia do SQL e isolamento billing/oficina em PostgreSQL local.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONTAINER_NAME="tc-e09-pg-test"

cleanup() {
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

trap cleanup EXIT
cleanup

docker run -d --name "$CONTAINER_NAME" \
  -e POSTGRES_PASSWORD=masterlocal \
  -e POSTGRES_USER=tcadmin \
  -e POSTGRES_DB=postgres \
  postgres:16-alpine >/dev/null

for _ in $(seq 1 30); do
  if docker exec "$CONTAINER_NAME" pg_isready -U tcadmin -d postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

export OS_DB_USERNAME=oficina
export BILLING_DB_USERNAME=billing
export OS_DATABASE_NAME=oficina
export BILLING_DATABASE_NAME=billing
export OS_CONNECTION_LIMIT=37
export BILLING_CONNECTION_LIMIT=22
export OFICINA_DB_PASSWORD=oficina-local-pass
export BILLING_DB_PASSWORD=billing-local-pass

apply_sql() {
  envsubst '$OS_DB_USERNAME $BILLING_DB_USERNAME $OS_DATABASE_NAME $BILLING_DATABASE_NAME $OS_CONNECTION_LIMIT $BILLING_CONNECTION_LIMIT $OFICINA_DB_PASSWORD $BILLING_DB_PASSWORD' \
    <"$ROOT/scripts/db-admin/provision.sql.tpl" \
    | docker exec -i "$CONTAINER_NAME" psql -v ON_ERROR_STOP=1 -U tcadmin -d postgres -q -f -
}

role_fingerprint() {
  docker exec "$CONTAINER_NAME" psql -U tcadmin -d postgres -Atc \
    "SELECT md5(string_agg(datname, ',' ORDER BY datname)) FROM pg_database WHERE datname IN ('oficina','billing');"
}

apply_sql
HASH1="$(role_fingerprint)"
apply_sql
HASH2="$(role_fingerprint)"

if [[ "$HASH1" != "$HASH2" ]]; then
  echo "Falha: segunda execucao alterou databases." >&2
  exit 1
fi

set +e
docker exec -e PGPASSWORD=billing-local-pass "$CONTAINER_NAME" \
  psql -U billing -d oficina -c 'SELECT 1' >/dev/null 2>&1
BILLING_ON_OFICINA=$?
docker exec -e PGPASSWORD=oficina-local-pass "$CONTAINER_NAME" \
  psql -U oficina -d billing -c 'SELECT 1' >/dev/null 2>&1
OFICINA_ON_BILLING=$?
set -e

if [[ "$BILLING_ON_OFICINA" -eq 0 ]]; then
  echo "Falha: usuario billing conectou em oficina." >&2
  exit 1
fi

if [[ "$OFICINA_ON_BILLING" -eq 0 ]]; then
  echo "Falha: usuario oficina conectou em billing." >&2
  exit 1
fi

echo "OK: idempotencia e isolamento validados localmente."