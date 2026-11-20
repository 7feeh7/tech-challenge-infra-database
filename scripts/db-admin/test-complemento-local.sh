#!/usr/bin/env bash
# Testes do complemento E09: entrypoint completo, segredos, falha SQL, idempotencia, isolamento e atributos.
# Requer Docker. Cenarios de senha fora do log: test-senha-fora-do-log-local.sh.
set -euo pipefail

# shellcheck source=scripts/db-admin/test-lib-local.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib-local.sh"

EXTRA_ROLE='sem_acesso_test'
EXTRA_ROLE_PASS='SemAcesso-Test-666'

setup_test_environment "tc-e09-complemento"

ENV_OK="${TEST_BASE}/env-ok"
write_env_file "$ENV_OK" 37 22

provisioned_state() {
  psql_admin "SELECT string_agg(datname || ':' || pg_get_userbyid(datdba), ',' ORDER BY datname)
    FROM pg_database WHERE datname IN ('oficina','billing')"
  psql_admin "SELECT string_agg(rolname || ':' || rolconnlimit || ':' || (rolsuper OR rolcreatedb OR rolcreaterole), ',' ORDER BY rolname)
    FROM pg_roles WHERE rolname IN ('oficina','billing')"
}

# Hash do verificador armazenado: muda se a senha for reaplicada, sem expor o valor.
password_fingerprint() {
  psql_admin "SELECT string_agg(md5(rolpassword), ',' ORDER BY rolname)
    FROM pg_authid WHERE rolname IN ('oficina','billing')"
}

echo "== Campo obrigatorio ausente (MASTER_SECRET_ARN) =="
write_mock_aws "$OFICINA_PASS" "$BILLING_PASS"
ENV_ABSENT="${TEST_BASE}/env-absent"
write_env_file "$ENV_ABSENT" 37 22
sed -i '/MASTER_SECRET_ARN/d' "$ENV_ABSENT"
expect_job_failure "campo ausente" "$ENV_ABSENT" "${TEST_BASE}/job-absent.log"
assert_no_secrets "campo-ausente" "${TEST_BASE}/job-absent.log"

echo "== Campo vazio no segredo (password oficina) =="
write_mock_aws "" "$BILLING_PASS"
expect_job_failure "campo vazio" "$ENV_OK" "${TEST_BASE}/job-empty.log"
assert_no_secrets "campo-vazio" "${TEST_BASE}/job-empty.log"
write_mock_aws "$OFICINA_PASS" "$BILLING_PASS"

echo "== Entrypoint completo (1a execucao) =="
expect_job_success "1a execucao" "$ENV_OK" "${TEST_BASE}/job-exec1.log"
assert_no_secrets "execucao-1" "${TEST_BASE}/job-exec1.log"
state_after_first_run="$(provisioned_state)"
fingerprint_after_first_run="$(password_fingerprint)"
[[ "$state_after_first_run" == *"billing:billing,oficina:oficina"* ]] || fail "donos dos databases inesperados."
[[ "$state_after_first_run" == *"billing:22:false,oficina:37:false"* ]] || fail "limites ou atributos dos papeis inesperados."
assert_scram_verifier_stored oficina
assert_scram_verifier_stored billing

echo "== Entrypoint completo (2a execucao idempotente) =="
expect_job_success "2a execucao" "$ENV_OK" "${TEST_BASE}/job-exec2.log"
assert_no_secrets "execucao-2" "${TEST_BASE}/job-exec2.log"
[[ "$(provisioned_state)" == "$state_after_first_run" ]] || fail "2a execucao alterou databases, donos, papeis ou limites."
[[ "$(password_fingerprint)" == "$fingerprint_after_first_run" ]] || fail "2a execucao reaplicou a senha."

echo "== Falha SQL (CONNECTION LIMIT invalido) =="
ENV_BAD_LIMIT="${TEST_BASE}/env-bad-limit"
write_env_file "$ENV_BAD_LIMIT" 'invalid' 22
expect_job_failure "limite invalido" "$ENV_BAD_LIMIT" "${TEST_BASE}/job-bad-limit.log"
assert_no_secrets "falha-sql-job" "${TEST_BASE}/job-bad-limit.log"
assert_server_log_clean "falha-sql-log-do-servidor"

echo "== Isolamento =="
psql_admin "CREATE ROLE ${EXTRA_ROLE} LOGIN PASSWORD '${EXTRA_ROLE_PASS}'" >/dev/null
assert_login_works oficina "$OFICINA_PASS" oficina
assert_login_works billing "$BILLING_PASS" billing
assert_connection_refused billing "$BILLING_PASS" oficina
assert_connection_refused oficina "$OFICINA_PASS" billing
assert_connection_refused oficina "$OFICINA_PASS" postgres
assert_connection_refused billing "$BILLING_PASS" postgres
assert_connection_refused oficina "$OFICINA_PASS" template1
assert_connection_refused billing "$BILLING_PASS" template1
assert_connection_refused "$EXTRA_ROLE" "$EXTRA_ROLE_PASS" oficina
assert_connection_refused "$EXTRA_ROLE" "$EXTRA_ROLE_PASS" billing

echo "== Atributos dos papeis =="
privileged_roles="$(psql_admin "SELECT count(*) FROM pg_roles
  WHERE rolname IN ('oficina','billing') AND (rolsuper OR rolcreatedb OR rolcreaterole)")"
[[ "$privileged_roles" == "0" ]] || fail "papel de aplicacao com SUPERUSER, CREATEDB ou CREATEROLE."

echo "== pg_stat_statements ao final =="
assert_pg_stat_statements_clean "pg-stat-statements-final"

echo "== Log do servidor ao final =="
assert_server_log_clean "log-do-servidor-final"

echo "OK: complemento E09 validado localmente (entrypoint, segredos, falha SQL, idempotencia, isolamento, atributos)."
