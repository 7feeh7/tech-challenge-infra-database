#!/usr/bin/env bash
# Testes do segundo complemento da E09: senha e verificador SCRAM fora do log do PostgreSQL, da saida do Job
# e da linha de comando. Le o log real do servidor (docker logs) e falha se nao conseguir coleta-lo.
# Requer Docker.
set -euo pipefail

# shellcheck source=scripts/db-admin/test-lib-local.sh
source "$(dirname "${BASH_SOURCE[0]}")/test-lib-local.sh"

setup_test_environment "tc-e09-senha-log"

ENV_OK="${TEST_BASE}/env-ok"
ENV_BAD_LIMIT="${TEST_BASE}/env-bad-limit"
write_env_file "$ENV_OK" 37 22
write_env_file "$ENV_BAD_LIMIT" 'invalid' 22

password_fingerprint() {
  psql_admin "SELECT md5(rolpassword) FROM pg_authid WHERE rolname = '$1'"
}

assert_app_logins_work() {
  assert_login_works oficina "$OFICINA_PASS" oficina
  assert_login_works billing "$BILLING_PASS" billing
}

assert_job_output_contains() {
  local file="$1" text="$2"
  grep -qaF -- "$text" "$file" || fail "saida do Job sem o trecho esperado: ${text}"
}

echo "== Guarda do log: nao coletavel, vazio e sem marcador falham =="
if collect_server_log "tc-e09-container-inexistente" "${TEST_BASE}/log-inexistente.txt" 2>/dev/null; then
  fail "coleta de log de contêiner inexistente deveria falhar."
fi
: >"${TEST_BASE}/log-vazio.txt"
echo "linha qualquer do servidor" >"${TEST_BASE}/log-sem-marcador.txt"
echo "marcador_conhecido" >"${TEST_BASE}/log-com-marcador.txt"
! require_log_marker "${TEST_BASE}/log-ausente.txt" "marcador_conhecido" || fail "arquivo ausente passou."
! require_log_marker "${TEST_BASE}/log-vazio.txt" "marcador_conhecido" || fail "log vazio passou."
! require_log_marker "${TEST_BASE}/log-sem-marcador.txt" "marcador_conhecido" || fail "log sem marcador passou."
require_log_marker "${TEST_BASE}/log-com-marcador.txt" "marcador_conhecido" || fail "log com marcador falhou."
(assert_no_secrets "arquivo-ausente" "${TEST_BASE}/log-ausente.txt") 2>/dev/null \
  && fail "asserção sobre arquivo inexistente passou."

echo "== Controle positivo: senha enviada sem supressao aparece no log (o detector enxerga) =="
psql_admin "CREATE ROLE controle_vazamento LOGIN PASSWORD '${CONTROL_PASS}'" >/dev/null
assert_server_log_reliable
grep -qaF -- "$CONTROL_PASS" "$SERVER_LOG" || fail "detector cego: senha de controle ausente do log."
psql_admin 'DROP ROLE controle_vazamento' >/dev/null

echo "== Controle positivo: sem suprimir o pg_stat_statements, o verificador aparece na view =="
verifier_in_pg_stat_statements_without_suppression \
  || fail "detector cego: verificador de controle ausente do pg_stat_statements."
psql_admin 'DROP ROLE controle_verificador' >/dev/null
psql_admin 'SELECT pg_stat_statements_reset()' >/dev/null

echo "== Sucesso: Job, log do servidor e linha de comando sem senha nem verificador =="
reset_provisioned_state
write_mock_aws "$OFICINA_PASS" "$BILLING_PASS"
expect_job_success "sucesso" "$ENV_OK" "${TEST_BASE}/job-success.log"
assert_no_secrets "sucesso-saida-do-job" "${TEST_BASE}/job-success.log"
assert_command_line_clean "sucesso-linha-de-comando"
assert_pg_stat_statements_clean "sucesso-pg-stat-statements"
assert_server_log_clean "sucesso-log-do-servidor"
assert_scram_verifier_stored oficina
assert_scram_verifier_stored billing
assert_app_logins_work
# O log traz a sessao do Job e o DDL do provisionamento: a ausencia de senha nao vem de log vazio.
grep -qaF 'connection authorized: user=tcadmin' "$SERVER_LOG" || fail "log sem a sessao do master."
grep -qaF 'statement: CREATE DATABASE oficina OWNER oficina' "$SERVER_LOG" || fail "log sem o DDL de provisionamento do Job."

echo "== Auditoria ativa nas demais sessoes depois do Job =="
audit_marker="auditoria_pos_job_${RANDOM}"
docker exec -e PGPASSWORD="$OFICINA_PASS" "$PG_NAME" \
  psql -h "$PG_NAME" -U oficina -d oficina -qc "CREATE TABLE ${audit_marker} (id int)"
collect_server_log "$PG_NAME" "$SERVER_LOG" || fail "nao foi possivel coletar o log do servidor."
require_log_marker "$SERVER_LOG" "$audit_marker" || fail "DDL de outra sessao depois do Job nao foi registrado."

echo "== Falha SQL de provisionamento (CONNECTION LIMIT invalido) a partir de estado limpo =="
reset_provisioned_state
expect_job_failure "falha SQL" "$ENV_BAD_LIMIT" "${TEST_BASE}/job-sql-failure.log"
assert_no_secrets "falha-sql-saida-do-job" "${TEST_BASE}/job-sql-failure.log"
assert_command_line_clean "falha-sql-linha-de-comando"
assert_server_log_clean "falha-sql-log-do-servidor"
role_exists oficina || fail "papeis deveriam existir (criados com senha antes do SQL que falhou)."
echo "== Reexecucao depois da falha SQL conclui e a senha vale =="
expect_job_success "reexecucao apos falha SQL" "$ENV_OK" "${TEST_BASE}/job-sql-rerun.log"
assert_no_secrets "reexecucao-apos-falha-sql" "${TEST_BASE}/job-sql-rerun.log"
assert_app_logins_work

echo "== Falha do CREATE ROLE de senha (erro do servidor) =="
reset_provisioned_state
docker exec "$PG_NAME" psql -v ON_ERROR_STOP=1 -U tcadmin -d postgres -qc \
  'ALTER ROLE tcadmin IN DATABASE postgres SET default_transaction_read_only = on'
expect_job_failure "falha do CREATE ROLE" "$ENV_OK" "${TEST_BASE}/job-create-failure.log"
# Reverte pelo template1: o ajuste vale so para o database postgres, onde o Job conecta.
docker exec "$PG_NAME" psql -v ON_ERROR_STOP=1 -U tcadmin -d template1 -qc \
  'ALTER ROLE tcadmin IN DATABASE postgres RESET default_transaction_read_only'
assert_no_secrets "falha-create-role-saida-do-job" "${TEST_BASE}/job-create-failure.log"
assert_job_output_contains "${TEST_BASE}/job-create-failure.log" "Falha ao criar o papel oficina"
! role_exists oficina || fail "papel oficina nao deveria existir depois da falha."
! role_exists billing || fail "papel billing nao deveria existir depois da falha."
assert_server_log_clean "falha-create-role-log-do-servidor"
expect_job_success "reexecucao apos falha do CREATE ROLE" "$ENV_OK" "${TEST_BASE}/job-create-rerun.log"
assert_app_logins_work

echo "== Falha do comando de senha depois do CREATE ROLE: sem papel parcial, reexecucao conclui =="
reset_provisioned_state
FAIL_PASSWORD_ROLE=billing expect_job_failure "falha do comando de senha" "$ENV_OK" "${TEST_BASE}/job-password-failure.log"
assert_no_secrets "falha-senha-saida-do-job" "${TEST_BASE}/job-password-failure.log"
assert_command_line_clean "falha-senha-linha-de-comando"
assert_job_output_contains "${TEST_BASE}/job-password-failure.log" "Passwords didn't match"
assert_job_output_contains "${TEST_BASE}/job-password-failure.log" "Falha ao criar o papel billing"
role_exists oficina || fail "papel oficina (concluido antes da falha) deveria existir."
! role_exists billing || fail "papel billing ficou sem senha: criacao nao foi atomica."
assert_server_log_clean "falha-senha-log-do-servidor"
oficina_fingerprint_before_rerun="$(password_fingerprint oficina)"
expect_job_success "reexecucao apos falha da senha" "$ENV_OK" "${TEST_BASE}/job-password-rerun.log"
assert_no_secrets "reexecucao-apos-falha-senha" "${TEST_BASE}/job-password-rerun.log"
assert_scram_verifier_stored billing
assert_pg_stat_statements_clean "reexecucao-pg-stat-statements"
assert_app_logins_work
[[ "$(password_fingerprint oficina)" == "$oficina_fingerprint_before_rerun" ]] \
  || fail "reexecucao reaplicou a senha de um papel ja concluido."
assert_server_log_clean "reexecucao-apos-falha-senha-log-do-servidor"

echo "== Permissao insuficiente: aborta antes de enviar credenciais =="
reset_provisioned_state
# Cria o master sem superusuario fora do log: a senha de teste dele tambem e marcador de vazamento.
printf "SET log_statement = 'none';\nSET pg_stat_statements.track = 'none';\nCREATE ROLE %s LOGIN CREATEROLE CREATEDB PASSWORD '%s';\n" \
  "$RESTRICTED_MASTER_USER" "$RESTRICTED_MASTER_PASS" \
  | docker exec -i "$PG_NAME" psql -v ON_ERROR_STOP=1 -q -U tcadmin -d postgres -f -
write_mock_aws "$OFICINA_PASS" "$BILLING_PASS" "$RESTRICTED_MASTER_USER" "$RESTRICTED_MASTER_PASS"
expect_job_failure "permissao insuficiente" "$ENV_OK" "${TEST_BASE}/job-restricted.log"
write_mock_aws "$OFICINA_PASS" "$BILLING_PASS"
assert_no_secrets "permissao-saida-do-job" "${TEST_BASE}/job-restricted.log"
# O psql aborta no primeiro SET e vive pouco demais para a amostragem garantir a captura.
assert_no_secrets "permissao-linha-de-comando" "$CMDLINES"
assert_job_output_contains "${TEST_BASE}/job-restricted.log" "Falha ao criar o papel oficina"
! role_exists oficina || fail "papel criado apesar da permissao insuficiente."
! role_exists billing || fail "papel criado apesar da permissao insuficiente."
assert_server_log_clean "permissao-log-do-servidor"
grep -qaF 'permission denied to set parameter' "$SERVER_LOG" || fail "log sem a recusa do SET de sessao."
psql_admin "DROP ROLE ${RESTRICTED_MASTER_USER}" >/dev/null

echo "== Senha com quebra de linha: rejeitada antes de qualquer SQL =="
reset_provisioned_state
write_mock_aws 'abc\ndef' "$BILLING_PASS"
expect_job_failure "senha com quebra de linha" "$ENV_OK" "${TEST_BASE}/job-newline.log"
write_mock_aws "$OFICINA_PASS" "$BILLING_PASS"
assert_no_secrets "quebra-de-linha-saida-do-job" "${TEST_BASE}/job-newline.log"
assert_job_output_contains "${TEST_BASE}/job-newline.log" "quebra de linha"
! role_exists oficina || fail "papel criado apesar da senha invalida."

echo "== Log final: criacao e senha dos papeis de aplicacao fora do log; demais DDL auditado =="
assert_server_log_clean "log-final"
! grep -qaE '(CREATE ROLE|(ALTER (ROLE|USER))) "?(oficina|billing)"? .*(PASSWORD|LOGIN)' "$SERVER_LOG" \
  || fail "log registrou criacao ou senha de papel de aplicacao fora da supressao."
# O que continua auditado: o ajuste de CONNECTION LIMIT, feito na sessao de provisionamento.
grep -qaF 'statement: ALTER ROLE "oficina" CONNECTION LIMIT 37;' "$SERVER_LOG" \
  || fail "log sem o ajuste de CONNECTION LIMIT do provisionamento."

echo "OK: senha e verificador fora do log do servidor, da saida do Job e da linha de comando."
