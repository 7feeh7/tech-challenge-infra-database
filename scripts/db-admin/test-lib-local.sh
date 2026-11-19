#!/usr/bin/env bash
# Biblioteca dos testes locais do Job administrativo (E09). Uso: source, depois setup_test_environment.
# PostgreSQL 16 descartavel numa rede Docker privada (sem porta publicada), com o registro equivalente ao
# do RDS e leitura do log real do servidor (docker logs). Valores de senha sao de teste e nunca impressos.

PG_IMAGE="postgres:16-alpine"
RUNNER_BASE_IMAGE="public.ecr.aws/aws-cli/aws-cli:2.27.25"

MASTER_PASS='MasterPass-Test-111'
OFICINA_PASS='Oficina-Secret-Test-222'
BILLING_PASS='Billing-Secret-Test-333'
CONTROL_PASS='Controle-Vazamento-444'
RESTRICTED_MASTER_USER='tcrestrito'
RESTRICTED_MASTER_PASS='Restrito-Test-555'

SECRET_MARKERS=("$MASTER_PASS" "$OFICINA_PASS" "$BILLING_PASS" "$RESTRICTED_MASTER_PASS")
# Forma de um verificador SCRAM-SHA-256: SCRAM-SHA-256$<iteracoes>:<salt>$<StoredKey>:<ServerKey>
SCRAM_VERIFIER_PATTERN='SCRAM-SHA-256\$[0-9]+:'

# O Git Bash converteria os caminhos Unix dos argumentos do docker.
export MSYS_NO_PATHCONV=1

fail() {
  echo "FALHA: $*" >&2
  exit 1
}

host_path_for_docker() {
  (cd "$1" && (pwd -W 2>/dev/null || pwd))
}

cleanup_test_environment() {
  docker rm -f "$PG_NAME" "$RUNNER_CONTAINER" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  docker rmi "$RUNNER_READY_IMAGE" >/dev/null 2>&1 || true
  if [[ "${KEEP_TEST_ARTIFACTS:-}" != "1" ]]; then
    chmod -R u+w "$TEST_BASE" 2>/dev/null || true
    rm -rf "$TEST_BASE"
  fi
}

# Uso: setup_test_environment <prefixo> (acrescenta o PID; define a rede, o PostgreSQL e as copias dos scripts so leitura).
setup_test_environment() {
  # PID no nome: execucoes simultaneas do mesmo teste nao derrubam o ambiente uma da outra.
  local prefix="$1-$$"
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[1]}")/../.." && pwd)"

  NET="${prefix}-net"
  PG_NAME="${prefix}-pg"
  RUNNER_CONTAINER="${prefix}-runner"
  RUNNER_READY_IMAGE="${prefix}-runner-ready:test"
  RUNNER_IMAGE_READY=""
  TEST_BASE="${root}/.local-test/${prefix}"
  SCRIPTS_RO="${TEST_BASE}/scripts-ro"
  WORK_HOST="${TEST_BASE}/work"
  WATCH_HOST="${TEST_BASE}/watch"
  MOCK_BIN="${TEST_BASE}/mock-bin"
  PSQL_WRAPPER="${TEST_BASE}/psql-wrapper"
  SERVER_LOG="${TEST_BASE}/server.log"
  CMDLINES="${TEST_BASE}/cmdlines.txt"

  trap cleanup_test_environment EXIT
  cleanup_test_environment

  mkdir -p "$SCRIPTS_RO" "$WORK_HOST" "$WATCH_HOST" "$MOCK_BIN" "$PSQL_WRAPPER"
  copy_scripts_read_only "$root"
  write_psql_wrapper
  start_postgres
  create_pg_stat_statements_extension
}

copy_scripts_read_only() {
  local root="$1"
  local script
  for script in entrypoint.sh provision.sql.tpl create-role-with-password.sql; do
    sed 's/\r$//' "${root}/scripts/db-admin/${script}" >"${SCRIPTS_RO}/${script}"
  done
  chmod a+x "${SCRIPTS_RO}/entrypoint.sh"
  chmod -R a-w "$SCRIPTS_RO"
}

# Registro equivalente ao parameter group do RDS (terraform/parameter_group.tf), mais o auto_explain
# e o pg_stat_statements carregados para exercitar a supressao de extensoes. Rede privada do Docker: nada em 0.0.0.0.
start_postgres() {
  docker network create "$NET" >/dev/null
  docker run -d --name "$PG_NAME" --network "$NET" \
    -e POSTGRES_PASSWORD="$MASTER_PASS" \
    -e POSTGRES_USER=tcadmin \
    -e POSTGRES_DB=postgres \
    "$PG_IMAGE" \
    -c log_statement=ddl \
    -c log_min_error_statement=error \
    -c log_connections=on \
    -c log_disconnections=on \
    -c shared_preload_libraries=auto_explain,pg_stat_statements \
    -c auto_explain.log_min_duration=0 >/dev/null

  # O servidor temporario da inicializacao tambem aceita conexoes locais: espera a inicializacao terminar.
  for _ in $(seq 1 90); do
    if docker logs "$PG_NAME" 2>&1 | grep -q 'init process complete' \
      && docker exec "$PG_NAME" pg_isready -h 127.0.0.1 -U tcadmin -d postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  fail "PostgreSQL de teste nao ficou pronto."
}

# A view fica no database do master (postgres), como no RDS.
create_pg_stat_statements_extension() {
  psql_admin 'CREATE EXTENSION pg_stat_statements' >/dev/null
}

psql_admin() {
  docker exec -e PGOPTIONS="-c client_min_messages=warning" "$PG_NAME" psql -v ON_ERROR_STOP=1 -U tcadmin -d postgres -Atc "$1"
}

# Conecta por TCP: o socket Unix da imagem usa trust e nao exercita a senha.
psql_as() {
  local user="$1" password="$2" database="$3" sql="$4"
  docker exec -e PGPASSWORD="$password" "$PG_NAME" \
    psql -h "$PG_NAME" -U "$user" -d "$database" -Atc "$sql" 2>&1
}

assert_login_works() {
  local user="$1" password="$2" database="$3"
  psql_as "$user" "$password" "$database" 'SELECT 1' >/dev/null \
    || fail "login de ${user} em ${database} com o valor do segredo deveria funcionar."
}

# Confere a causa (privilegio), para a recusa nao passar por senha errada.
assert_connection_refused() {
  local user="$1" password="$2" database="$3"
  local output
  if output="$(psql_as "$user" "$password" "$database" 'SELECT 1')"; then
    fail "conexao indevida de ${user} em ${database} obteve sucesso."
  fi
  [[ "$output" == *"permission denied for database"* ]] \
    || fail "conexao de ${user} em ${database} recusada por motivo inesperado."
}

# Devolve o PostgreSQL ao estado anterior ao Job (inclusive o CONNECT de PUBLIC revogado pelo Job).
reset_provisioned_state() {
  psql_admin 'DROP DATABASE IF EXISTS oficina WITH (FORCE)' >/dev/null
  psql_admin 'DROP DATABASE IF EXISTS billing WITH (FORCE)' >/dev/null
  psql_admin 'DROP ROLE IF EXISTS oficina' >/dev/null
  psql_admin 'DROP ROLE IF EXISTS billing' >/dev/null
  psql_admin 'GRANT CONNECT ON DATABASE postgres TO PUBLIC' >/dev/null
  psql_admin 'GRANT CONNECT ON DATABASE template1 TO PUBLIC' >/dev/null
}

role_exists() {
  [[ "$(psql_admin "SELECT count(*) FROM pg_roles WHERE rolname = '$1'")" == "1" ]]
}

# Confere, como superusuario do teste, que a senha armazenada e um verificador SCRAM-SHA-256.
assert_scram_verifier_stored() {
  local stored_count
  stored_count="$(psql_admin "SELECT count(*) FROM pg_authid WHERE rolname = '$1' AND rolpassword LIKE 'SCRAM-SHA-256\$%'")"
  [[ "$stored_count" == "1" ]] || fail "papel $1 sem verificador SCRAM-SHA-256 armazenado."
}

write_mock_aws() {
  local oficina_pass="$1" billing_pass="$2"
  local master_user="${3:-tcadmin}" master_pass="${4:-$MASTER_PASS}"
  cat >"${MOCK_BIN}/aws" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "secretsmanager" && "\${2:-}" == "get-secret-value" ]]; then
  arn=""
  shift 2
  while [[ \$# -gt 0 ]]; do
    case "\$1" in
      --secret-id) arn="\$2"; shift 2 ;;
      --region|--query|--output) shift 2 ;;
      *) shift ;;
    esac
  done
  case "\$arn" in
    master)
      printf '%s\n' '{"username":"${master_user}","password":"${master_pass}","host":"${PG_NAME}","port":"5432","dbname":"postgres"}'
      ;;
    oficina) printf '%s\n' "{\"password\":\"${oficina_pass}\"}" ;;
    billing) printf '%s\n' "{\"password\":\"${billing_pass}\"}" ;;
    *) printf '%s\n' '{}' ;;
  esac
  exit 0
fi
echo "mock aws: comando nao suportado" >&2
exit 1
EOF
  chmod +x "${MOCK_BIN}/aws"
}

# Injeta falha no comando de senha: entrega ao \password do papel em FAIL_PASSWORD_ROLE duas senhas
# diferentes, que o psql rejeita depois do CREATE ROLE e antes de gravar a senha.
write_psql_wrapper() {
  cat >"${PSQL_WRAPPER}/psql" <<'EOF'
#!/usr/bin/env bash
real_psql="$(PATH="${PATH#/mock/psql-wrapper:}" command -v psql)"
if [[ -n "${FAIL_PASSWORD_ROLE:-}" && "$*" == *"role=${FAIL_PASSWORD_ROLE}"* ]]; then
  exec "$real_psql" "$@" < <(printf 'primeira\nsegunda\n')
fi
exec "$real_psql" "$@"
EOF
  chmod +x "${PSQL_WRAPPER}/psql"
}

write_env_file() {
  local path="$1" os_limit="$2" billing_limit="$3"
  cat >"$path" <<EOF
AWS_REGION=us-east-1
MASTER_SECRET_ARN=master
OFICINA_USER_SECRET_ARN=oficina
BILLING_USER_SECRET_ARN=billing
OS_DB_USERNAME=oficina
BILLING_DB_USERNAME=billing
OS_DATABASE_NAME=oficina
BILLING_DATABASE_NAME=billing
OS_CONNECTION_LIMIT=${os_limit}
BILLING_CONNECTION_LIMIT=${billing_limit}
WORK_DIR=/tmp/db-admin-work
EOF
}

# Amostra a linha de comando de todos os processos do contêiner enquanto o entrypoint roda (/watch).
RUNNER_COMMAND='
( while :; do grep -a "" /proc/[0-9]*/cmdline 2>/dev/null; done >/watch/cmdlines ) &
watcher=$!
/scripts/entrypoint.sh
code=$?
kill "$watcher" 2>/dev/null
exit "$code"
'

# Instala as dependencias (psql, jq, envsubst) pelo proprio caminho do entrypoint uma unica vez e reaproveita
# a imagem nas execucoes seguintes, para os testes nao reinstalarem pacotes a cada Job.
save_runner_image_if_ready() {
  [[ -z "$RUNNER_IMAGE_READY" ]] || return 0
  docker commit "$RUNNER_CONTAINER" "$RUNNER_READY_IMAGE" >/dev/null
  if docker run --rm --entrypoint /bin/bash "$RUNNER_READY_IMAGE" \
    -c 'command -v psql && command -v jq && command -v envsubst' >/dev/null 2>&1; then
    RUNNER_IMAGE_READY=1
  else
    docker rmi "$RUNNER_READY_IMAGE" >/dev/null 2>&1 || true
  fi
}

# Uso: run_entrypoint <env-file> <arquivo-de-saida>
# Devolve o codigo de saida do Job; stdout e stderr do Job vao para o arquivo de saida.
# Com FAIL_PASSWORD_ROLE=<papel> no ambiente, o comando de senha desse papel falha (psql de teste).
run_entrypoint() {
  local env_file="$1" output_file="$2"
  local image="$RUNNER_BASE_IMAGE"
  [[ -z "$RUNNER_IMAGE_READY" ]] || image="$RUNNER_READY_IMAGE"

  # O wrapper so entra quando pedido: nas demais execucoes o entrypoint instala e usa o psql real.
  local failure_injection=()
  if [[ -n "${FAIL_PASSWORD_ROLE:-}" ]]; then
    failure_injection=(
      -v "$(host_path_for_docker "$PSQL_WRAPPER")/psql:/mock/psql-wrapper/psql:ro"
      -e "FAIL_PASSWORD_ROLE=${FAIL_PASSWORD_ROLE}"
    )
  fi

  docker rm -f "$RUNNER_CONTAINER" >/dev/null 2>&1 || true
  : >"${WATCH_HOST}/cmdlines"

  local exit_code=0
  docker run --name "$RUNNER_CONTAINER" --network "$NET"     --entrypoint /bin/bash     -v "$(host_path_for_docker "$SCRIPTS_RO"):/scripts:ro"     -v "$(host_path_for_docker "$WORK_HOST"):/tmp/db-admin-work"     -v "$(host_path_for_docker "$WATCH_HOST"):/watch"     -v "$(host_path_for_docker "$MOCK_BIN")/aws:/mock/bin/aws:ro"     --env-file "$(host_path_for_docker "$(dirname "$env_file")")/$(basename "$env_file")"     -e AWS_ACCESS_KEY_ID=test     -e AWS_SECRET_ACCESS_KEY=test     -e PATH=/mock/psql-wrapper:/mock/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin     "${failure_injection[@]}"     "$image"     -c "$RUNNER_COMMAND" >"$output_file" 2>&1 || exit_code=$?

  tr '\0' ' ' <"${WATCH_HOST}/cmdlines" >"$CMDLINES"
  save_runner_image_if_ready
  return "$exit_code"
}

expect_job_success() {
  local label="$1"
  shift
  run_entrypoint "$@" || fail "Job deveria concluir (${label}); veja a saida em ${2}."
}

expect_job_failure() {
  local label="$1"
  shift
  if run_entrypoint "$@"; then
    fail "Job deveria falhar (${label})."
  fi
}

# Falha se algum arquivo estiver ausente ou vazio: asserção sobre arquivo inexistente nao prova nada.
assert_no_secrets() {
  local label="$1"
  shift
  local file marker
  for file in "$@"; do
    [[ -s "$file" ]] || fail "[${label}] arquivo ausente ou vazio, nada a conferir: $(basename "$file")."
    for marker in "${SECRET_MARKERS[@]}"; do
      ! grep -qaF -- "$marker" "$file" || fail "[${label}] $(basename "$file") contem senha de teste."
    done
    ! grep -qaE -- "$SCRAM_VERIFIER_PATTERN" "$file" \
      || fail "[${label}] $(basename "$file") contem verificador SCRAM."
  done
}

# Coleta o log real do servidor (stderr do contêiner). Falha se o docker nao conseguir ler.
collect_server_log() {
  local container="$1" file="$2"
  docker logs "$container" >"$file" 2>&1
}

# O log so vale como prova se existir, nao estiver vazio e trouxer o marcador de outra sessao.
require_log_marker() {
  local file="$1" marker="$2"
  [[ -f "$file" && -s "$file" ]] && grep -qaF -- "$marker" "$file"
}

assert_server_log_reliable() {
  local marker="marcador_log_${RANDOM}${RANDOM}"
  psql_admin "CREATE TABLE ${marker} (id int); DROP TABLE ${marker}" >/dev/null
  collect_server_log "$PG_NAME" "$SERVER_LOG" || fail "nao foi possivel coletar o log do servidor."
  require_log_marker "$SERVER_LOG" "$marker" \
    || fail "log do servidor vazio ou sem o marcador de outra sessao."
}

assert_server_log_clean() {
  assert_server_log_reliable
  assert_no_secrets "$1" "$SERVER_LOG"
}

# pg_stat_statements guarda o texto de comandos utilitarios (como ALTER USER ... PASSWORD) sem normalizar.
# Os marcadores de senha so sao procurados no arquivo despejado: em consulta SQL eles iriam para o log do
# servidor (auto_explain registra o texto do SELECT).
assert_pg_stat_statements_clean() {
  local label="$1" marker="pgss_marcador_${RANDOM}${RANDOM}"
  local dump="${TEST_BASE}/pg-stat-statements.txt"
  psql_admin "CREATE TABLE ${marker} (id int); DROP TABLE ${marker}" >/dev/null
  psql_admin "SELECT query FROM pg_stat_statements" >"$dump"
  grep -qaF -- "$marker" "$dump" || fail "[${label}] pg_stat_statements vazio ou sem o marcador de outra sessao."
  assert_no_secrets "$label" "$dump"
}

# Controle positivo: reproduz a sessao de senha do Job sem suprimir o pg_stat_statements. O log do servidor
# fica suprimido so para o verificador de controle nao entrar no log lido pelos demais testes.
verifier_in_pg_stat_statements_without_suppression() {
  local script="${TEST_BASE}/controle-verificador.sql"
  printf "SET log_statement = 'none';\nSET log_min_error_statement = 'panic';\nCREATE ROLE controle_verificador LOGIN;\n\\\\password controle_verificador\n" >"$script"
  docker cp "$(host_path_for_docker "$TEST_BASE")/controle-verificador.sql" "${PG_NAME}:/tmp/controle-verificador.sql"
  printf '%s\n%s\n' "$CONTROL_PASS" "$CONTROL_PASS" \
    | docker exec -i "$PG_NAME" psql -v ON_ERROR_STOP=1 -q -U tcadmin -d postgres -f /tmp/controle-verificador.sql >/dev/null 2>&1
  [[ "$(psql_admin "SELECT count(*) FROM pg_stat_statements WHERE query ~ '${SCRAM_VERIFIER_PATTERN}'")" -ge 1 ]]
}

assert_command_line_clean() {
  assert_no_secrets "$1" "$CMDLINES"
  grep -qaF 'create-role-with-password.sql' "$CMDLINES" \
    || fail "[$1] amostragem de processos nao viu o psql de senha."
}
