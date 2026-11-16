#!/usr/bin/env bash
# Testes do complemento E09: entrypoint completo, segredos, falha SQL, idempotencia, isolamento.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NET="tc-e09-complemento-net"
PG_NAME="tc-e09-complemento-pg"
RUNNER_IMAGE="public.ecr.aws/aws-cli/aws-cli:2.27.25"

MASTER_PASS='MasterPass-Test-111'
OFICINA_PASS='Oficina-Secret-Test-222'
BILLING_PASS='Billing-Secret-Test-333'
EXTRA_ROLE='sem_acesso_test'

SECRET_MARKERS=("$MASTER_PASS" "$OFICINA_PASS" "$BILLING_PASS")

TEST_BASE="$ROOT/.local-test/e09-complemento"
SCRIPTS_RO="$TEST_BASE/scripts-ro"
WORK_HOST="$TEST_BASE/work"
MOCK_BIN="$TEST_BASE/mock-bin"

cleanup() {
  docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  if [[ "${KEEP_TEST_ARTIFACTS:-}" != "1" ]]; then
    rm -rf "$TEST_BASE"
  fi
}

trap cleanup EXIT
cleanup

docker network create "$NET" >/dev/null
docker run -d --name "$PG_NAME" --network "$NET" \
  -e POSTGRES_PASSWORD="$MASTER_PASS" \
  -e POSTGRES_USER=tcadmin \
  -e POSTGRES_DB=postgres \
  postgres:16-alpine >/dev/null

for _ in $(seq 1 45); do
  if docker exec "$PG_NAME" pg_isready -U tcadmin -d postgres >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

docker exec "$PG_NAME" psql -U tcadmin -d postgres -c "ALTER SYSTEM SET log_statement = 'ddl';" >/dev/null
docker exec "$PG_NAME" psql -U tcadmin -d postgres -c "SELECT pg_reload_conf();" >/dev/null

rm -rf "$TEST_BASE"
mkdir -p "$SCRIPTS_RO" "$WORK_HOST" "$MOCK_BIN"
sed 's/\r$//' "$ROOT/scripts/db-admin/entrypoint.sh" >"$SCRIPTS_RO/entrypoint.sh"
cp -a "$ROOT/scripts/db-admin/provision.sql.tpl" "$SCRIPTS_RO/"
chmod -R a-w "$SCRIPTS_RO"
chmod a+x "$SCRIPTS_RO/entrypoint.sh"

write_mock_aws() {
  local oficina_pw="$1"
  local billing_pw="$2"
  cat >"$MOCK_BIN/aws" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "secretsmanager" && "\${2:-}" == "get-secret-value" ]]; then
  arn=""
  shift 2
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --secret-id) arn="\$2"; shift 2 ;;
      --region) shift 2 ;;
      --query) shift 2 ;;
      --output) shift 2 ;;
      *) shift ;;
    esac
  done
  case "\$arn" in
    master)
      printf '%s\n' '{"username":"tcadmin","password":"${MASTER_PASS}","host":"${PG_NAME}","port":"5432","dbname":"postgres"}'
      ;;
    oficina)
      printf '%s\n' "{\"password\":\"${oficina_pw}\"}"
      ;;
    billing)
      printf '%s\n' "{\"password\":\"${billing_pw}\"}"
      ;;
    *)
      printf '%s\n' '{}'
      ;;
  esac
  exit 0
fi
echo "mock aws: comando nao suportado" >&2
exit 1
EOF
  chmod +x "$MOCK_BIN/aws"
}

assert_no_secrets() {
  local label="$1"
  local file="$2"
  local m
  for m in "${SECRET_MARKERS[@]}"; do
    if grep -qF "$m" "$file" 2>/dev/null; then
      echo "Falha [$label]: saida contem marcador de senha de teste." >&2
      exit 1
    fi
  done
}

win_path() {
  (cd "$1" && pwd -W)
}

run_entrypoint() {
  local env_file="$1"
  local log_file="$2"
  local scripts_vol work_vol mock_vol
  scripts_vol="$(win_path "$SCRIPTS_RO")"
  work_vol="$(win_path "$WORK_HOST")"
  mock_vol="$(win_path "$MOCK_BIN")"
  env_vol="$(cd "$(dirname "$env_file")" && pwd -W)/$(basename "$env_file")"
  MSYS_NO_PATHCONV=1 docker run --rm --network "$NET" \
    --entrypoint /bin/bash \
    -v "${scripts_vol}:/scripts:ro" \
    -v "${work_vol}:/tmp/db-admin-work" \
    -v "${mock_vol}/aws:/mock/bin/aws:ro" \
    --env-file "$env_vol" \
    -e AWS_ACCESS_KEY_ID=test \
    -e AWS_SECRET_ACCESS_KEY=test \
    -e PATH=/mock/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    "$RUNNER_IMAGE" \
    -c '/scripts/entrypoint.sh' >"$log_file" 2>&1
  return $?
}

write_env_file() {
  local path="$1"
  local limit_os="$2"
  local limit_billing="$3"
  cat >"$path" <<EOF
AWS_REGION=us-east-1
MASTER_SECRET_ARN=master
OFICINA_USER_SECRET_ARN=oficina
BILLING_USER_SECRET_ARN=billing
OS_DB_USERNAME=oficina
BILLING_DB_USERNAME=billing
OS_DATABASE_NAME=oficina
BILLING_DATABASE_NAME=billing
OS_CONNECTION_LIMIT=${limit_os}
BILLING_CONNECTION_LIMIT=${limit_billing}
WORK_DIR=/tmp/db-admin-work
EOF
}

write_mock_aws "$OFICINA_PASS" "$BILLING_PASS"

echo "== Campo obrigatorio ausente (MASTER_SECRET_ARN) =="
env_absent="$TEST_BASE/env-absent"
write_env_file "$env_absent" 37 22
sed -i '/MASTER_SECRET_ARN/d' "$env_absent"
log_absent="$TEST_BASE/log-absent"
set +e
run_entrypoint "$env_absent" "$log_absent"
code_absent=$?
set -e
if [[ "$code_absent" -eq 0 ]]; then
  echo "Falha: esperava erro com MASTER_SECRET_ARN ausente." >&2
  exit 1
fi
assert_no_secrets "campo-ausente" "$log_absent"

echo "== Campo vazio no segredo (password oficina) =="
write_mock_aws "" "$BILLING_PASS"
log_empty="$TEST_BASE/log-empty"
env_ok="$TEST_BASE/env-ok"
write_env_file "$env_ok" 37 22
set +e
run_entrypoint "$env_ok" "$log_empty"
code_empty=$?
set -e
write_mock_aws "$OFICINA_PASS" "$BILLING_PASS"
if [[ "$code_empty" -eq 0 ]]; then
  echo "Falha: esperava erro com password oficina vazio." >&2
  exit 1
fi
assert_no_secrets "campo-vazio" "$log_empty"

echo "== Entrypoint completo (1a execucao) =="
log1="$TEST_BASE/log-exec1"
run_entrypoint "$env_ok" "$log1"
assert_no_secrets "execucao-1" "$log1"

echo "== Entrypoint completo (2a execucao idempotente) =="
log2="$TEST_BASE/log-exec2"
run_entrypoint "$env_ok" "$log2"
assert_no_secrets "execucao-2" "$log2"

fp1="$(docker exec "$PG_NAME" psql -U tcadmin -d postgres -Atc \
  "SELECT string_agg(datname||':'||pg_catalog.pg_get_userbyid(datdba), ',' ORDER BY datname) FROM pg_database WHERE datname IN ('oficina','billing');")"
run_entrypoint "$env_ok" /dev/null
fp2="$(docker exec "$PG_NAME" psql -U tcadmin -d postgres -Atc \
  "SELECT string_agg(datname||':'||pg_catalog.pg_get_userbyid(datdba), ',' ORDER BY datname) FROM pg_database WHERE datname IN ('oficina','billing');")"
limits="$(docker exec "$PG_NAME" psql -U tcadmin -d postgres -Atc \
  "SELECT rolname||':'||rolconnlimit FROM pg_roles WHERE rolname IN ('oficina','billing') ORDER BY rolname;")"
if [[ "$fp1" != "$fp2" ]]; then
  echo "Falha: idempotencia alterou databases/donos." >&2
  exit 1
fi
if [[ "$limits" != *"billing:22"* || "$limits" != *"oficina:37"* ]]; then
  echo "Falha: CONNECTION LIMIT esperado 37/22, obteve: $limits" >&2
  exit 1
fi

echo "== Falha SQL (CONNECTION LIMIT invalido) =="
log_fail="$TEST_BASE/log-fail"
env_bad="$TEST_BASE/env-bad"
write_env_file "$env_bad" 'invalid' 22
set +e
run_entrypoint "$env_bad" "$log_fail"
code_fail=$?
set -e
if [[ "$code_fail" -eq 0 ]]; then
  echo "Falha: esperava erro SQL com limite invalido." >&2
  exit 1
fi
assert_no_secrets "falha-sql-job" "$log_fail"
pg_log_file="$TEST_BASE/pg.log"
docker exec "$PG_NAME" sh -c 'cat /var/lib/postgresql/data/log/*.log 2>/dev/null || true' >"$pg_log_file" || true
assert_no_secrets "falha-sql-pglog" "$pg_log_file"

echo "== Isolamento e atributos =="
docker exec "$PG_NAME" psql -U tcadmin -d postgres -qc \
  "DO \$\$ BEGIN IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${EXTRA_ROLE}') THEN CREATE ROLE ${EXTRA_ROLE} LOGIN PASSWORD 'x'; END IF; END \$\$;" >/dev/null

set +e
docker exec -e PGPASSWORD="$BILLING_PASS" "$PG_NAME" psql -U billing -d oficina -c 'SELECT 1' >/dev/null 2>&1
cross_billing=$?
docker exec -e PGPASSWORD="$OFICINA_PASS" "$PG_NAME" psql -U oficina -d billing -c 'SELECT 1' >/dev/null 2>&1
cross_oficina=$?
docker exec -e PGPASSWORD="$OFICINA_PASS" "$PG_NAME" psql -U oficina -d postgres -c 'SELECT 1' >/dev/null 2>&1
oficina_postgres=$?
docker exec -e PGPASSWORD="$BILLING_PASS" "$PG_NAME" psql -U billing -d postgres -c 'SELECT 1' >/dev/null 2>&1
billing_postgres=$?
docker exec -e PGPASSWORD="$OFICINA_PASS" "$PG_NAME" psql -U oficina -d template1 -c 'SELECT 1' >/dev/null 2>&1
oficina_template=$?
docker exec -e PGPASSWORD=x "$PG_NAME" psql -U "$EXTRA_ROLE" -d oficina -c 'SELECT 1' >/dev/null 2>&1
extra_oficina=$?
docker exec -e PGPASSWORD=x "$PG_NAME" psql -U "$EXTRA_ROLE" -d billing -c 'SELECT 1' >/dev/null 2>&1
extra_billing=$?
set -e

isolation_cases=(
  "billing->oficina:$cross_billing"
  "oficina->billing:$cross_oficina"
  "oficina->postgres:$oficina_postgres"
  "billing->postgres:$billing_postgres"
  "oficina->template1:$oficina_template"
  "${EXTRA_ROLE}->oficina:$extra_oficina"
  "${EXTRA_ROLE}->billing:$extra_billing"
)
for item in "${isolation_cases[@]}"; do
  label="${item%%:*}"
  code="${item##*:}"
  if [[ "$code" -eq 0 ]]; then
    echo "Falha: conexao indevida obteve sucesso (${label})." >&2
    exit 1
  fi
done

attrs="$(docker exec "$PG_NAME" psql -U tcadmin -d postgres -Atc \
  "SELECT rolname, rolsuper, rolcreatedb, rolcreaterole FROM pg_roles WHERE rolname IN ('oficina','billing') ORDER BY rolname;")"
if echo "$attrs" | grep -q 't'; then
  echo "Falha: papel com privilegio elevado: $attrs" >&2
  exit 1
fi

docker exec -e PGPASSWORD="$OFICINA_PASS" "$PG_NAME" psql -U oficina -d oficina -c 'SELECT 1' >/dev/null
docker exec -e PGPASSWORD="$BILLING_PASS" "$PG_NAME" psql -U billing -d billing -c 'SELECT 1' >/dev/null

echo "OK: complemento E09 validado localmente (entrypoint, segredos, falha SQL, idempotencia, isolamento, atributos)."