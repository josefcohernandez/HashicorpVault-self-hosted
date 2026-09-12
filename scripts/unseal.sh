#!/usr/bin/env bash
# Desella Vault. Usa secrets/vault-init.json si existe; si no, pide las claves por teclado.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require jq
ensure_running

is_initialized || die "Vault no está inicializado. Ejecuta scripts/init.sh"

if ! is_sealed; then
  log "Vault ya está desellado."
  exit 0
fi

threshold="$(vault_status_json | jq -r '.t')"

if [[ -f "$INIT_FILE" ]]; then
  log "Usando claves de $INIT_FILE (umbral: $threshold)"
  mapfile -t keys < <(jq -r '.unseal_keys_b64[]' "$INIT_FILE")
  for key in "${keys[@]}"; do
    printf '%s\n' "$key" | vault_unseal_stdin
    if ! is_sealed; then break; fi
  done
else
  warn "No existe $INIT_FILE. Introduce $threshold claves de unseal manualmente."
  for ((i = 1; i <= threshold; i++)); do
    read -rsp "Clave de unseal $i/$threshold: " key; echo
    printf '%s\n' "$key" | vault_unseal_stdin
    if ! is_sealed; then break; fi
  done
fi

wait_unsealed 20 || die "Vault sigue sellado. Revisa las claves."
log "Vault desellado correctamente."
