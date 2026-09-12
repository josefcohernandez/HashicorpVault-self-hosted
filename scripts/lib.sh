#!/usr/bin/env bash
# Funciones comunes para los scripts. No ejecutar directamente: se hace "source".
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"
SECRETS_DIR="$ROOT_DIR/secrets"
BACKUP_DIR="$ROOT_DIR/backups"
INIT_FILE="$SECRETS_DIR/vault-init.json"
BACKUP_TOKEN_FILE="$SECRETS_DIR/backup.token"

log()  { printf '\033[1;34m[%s]\033[0m %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '\033[1;33m[AVISO]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "No existe $ENV_FILE. Copia .env.example a .env y rellénalo."
# shellcheck disable=SC1090
set -a; source "$ENV_FILE"; set +a

COMPOSE=(docker compose -f "$ROOT_DIR/docker-compose.yml" --env-file "$ENV_FILE")

require() { command -v "$1" >/dev/null 2>&1 || die "Necesitas '$1' instalado en el host."; }

# Ejecuta el CLI de vault dentro del contenedor. Propaga VAULT_TOKEN si está definido.
# stdin se cierra (/dev/null): "docker compose exec -T" consumiría la entrada del script
# (por ejemplo, una confirmación escrita por teclado o un pipe).
vault_exec() {
  vault_exec_stdin "$@" </dev/null
}

# Igual que vault_exec pero deja pasar stdin (para "password=-" o similares).
vault_exec_stdin() {
  local env_args=()
  [[ -n "${VAULT_TOKEN:-}" ]] && env_args+=(-e "VAULT_TOKEN=$VAULT_TOKEN")
  "${COMPOSE[@]}" exec -T "${env_args[@]}" vault vault "$@"
}

# Desella con una clave leída por stdin. La clave se lee con "read" dentro del contenedor
# para que nunca aparezca en la lista de procesos del host.
vault_unseal_stdin() {
  "${COMPOSE[@]}" exec -T vault sh -c 'IFS= read -r k; exec vault operator unseal -format=json "$k"' >/dev/null
}

# Devuelve el JSON de "vault status" (sale con código 2 si está sellado, por eso el || true).
# Justo después de desellar, Vault puede responder vacío unos instantes: se reintenta.
vault_status_json() {
  local out
  for _ in 1 2 3 4 5; do
    out="$(vault_exec status -format=json 2>/dev/null || true)"
    if [[ -n "$out" ]]; then printf '%s' "$out"; return 0; fi
    sleep 1
  done
  return 1
}

# Espera hasta N segundos a que Vault esté desellado. Devuelve 1 si sigue sellado.
wait_unsealed() {
  local timeout="${1:-20}"
  for ((i = 0; i < timeout; i++)); do
    is_sealed || return 0
    sleep 1
  done
  return 1
}

ensure_running() {
  local state
  state="$("${COMPOSE[@]}" ps --format '{{.State}}' vault 2>/dev/null || true)"
  [[ "$state" == "running" ]] || die "El contenedor vault no está en ejecución. Arranca con: docker compose up -d"
}

is_initialized() { [[ "$(vault_status_json | jq -r '.initialized // false')" == "true" ]]; }
is_sealed()      { [[ "$(vault_status_json | jq -r 'if .sealed == null then true else .sealed end')" == "true" ]]; }

# Token root desde VAULT_TOKEN o desde secrets/vault-init.json
root_token() {
  if [[ -n "${VAULT_TOKEN:-}" ]]; then
    printf '%s' "$VAULT_TOKEN"
  elif [[ -f "$INIT_FILE" ]]; then
    jq -r '.root_token' "$INIT_FILE"
  else
    die "No hay token: exporta VAULT_TOKEN o asegúrate de que existe $INIT_FILE"
  fi
}
