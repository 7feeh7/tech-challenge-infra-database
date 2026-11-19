#!/usr/bin/env bash
# Verifica que as senhas geradas em terraform/secrets.tf nao exigem codificacao em URL.
# Uso: bash scripts/validate-password-charset.sh [arquivo.tf]
set -euo pipefail

SECRETS_FILE="${1:-$(dirname "${BASH_SOURCE[0]}")/../terraform/secrets.tf}"
# Caracteres nao reservados da RFC 3986 que nao sao alfanumericos.
UNRESERVED_SPECIALS_PATTERN='^[-_.~]+$'
MIN_PASSWORD_LENGTH=16
REQUIRED_PASSWORDS=(master_db_password oficina_db_password billing_db_password)

errors=0
found_passwords=()

fail() {
  echo "FALHA: $*" >&2
  errors=$((errors + 1))
}

attribute_value() {
  local block="$1"
  local attribute="$2"
  sed -n -E "s/^[[:space:]]*${attribute}[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" <<<"$block"
}

validate_password_block() {
  local name="$1"
  local block="$2"
  local override_special length minimum

  found_passwords+=("$name")

  if [[ "$(attribute_value "$block" special)" != "true" ]]; then
    fail "${name}: special deve ser true"
  fi

  override_special="$(attribute_value "$block" override_special)"
  if [[ -z "$override_special" ]]; then
    fail "${name}: override_special ausente (o padrao do provider inclui caracteres reservados em URL)"
  elif [[ ! "$override_special" =~ $UNRESERVED_SPECIALS_PATTERN ]]; then
    fail "${name}: override_special \"${override_special}\" tem caractere fora de [-_.~]"
  fi

  length="$(attribute_value "$block" length)"
  if [[ ! "$length" =~ ^[0-9]+$ ]] || ((length < MIN_PASSWORD_LENGTH)); then
    fail "${name}: length deve ser >= ${MIN_PASSWORD_LENGTH}"
  fi

  for minimum in min_upper min_lower min_numeric min_special; do
    if [[ ! "$(attribute_value "$block" "$minimum")" =~ ^[1-9][0-9]*$ ]]; then
      fail "${name}: ${minimum} deve ser >= 1"
    fi
  done
}

current_name=""
current_block=""
while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  if [[ "$line" =~ ^resource[[:space:]]+\"random_password\"[[:space:]]+\"([^\"]+)\" ]]; then
    current_name="${BASH_REMATCH[1]}"
    current_block=""
  elif [[ -n "$current_name" && "$line" == "}" ]]; then
    validate_password_block "$current_name" "$current_block"
    current_name=""
  elif [[ -n "$current_name" ]]; then
    current_block+="${line}"$'\n'
  fi
done <"$SECRETS_FILE"

for required in "${REQUIRED_PASSWORDS[@]}"; do
  if [[ ! " ${found_passwords[*]:-} " == *" ${required} "* ]]; then
    fail "random_password.${required} nao encontrado em ${SECRETS_FILE}"
  fi
done

if ((errors > 0)); then
  exit 1
fi
echo "OK: ${#found_passwords[@]} senhas geradas usam so [A-Za-z0-9] e [-_.~]."
