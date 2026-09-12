#!/usr/bin/env bash
# Inicializa Vault (genera claves Shamir y root token) y lo desella.
# Las claves se guardan en secrets/vault-init.json (fuera de git, permisos 600).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require jq
ensure_running

if is_initialized; then
  warn "Vault ya está inicializado. Nada que hacer."
  if is_sealed; then
    log "Está sellado. Ejecuta scripts/unseal.sh"
  fi
  exit 0
fi

[[ -f "$INIT_FILE" ]] && die "Ya existe $INIT_FILE pero Vault no está inicializado. Muévelo o bórralo antes de continuar."

shares="${VAULT_KEY_SHARES:-5}"
threshold="${VAULT_KEY_THRESHOLD:-3}"

log "Inicializando Vault con $shares claves y umbral $threshold..."
umask 077
vault_exec operator init \
  -key-shares="$shares" \
  -key-threshold="$threshold" \
  -format=json > "$INIT_FILE"
chmod 600 "$INIT_FILE"

log "Claves guardadas en $INIT_FILE"
log "Desellando..."
"$ROOT_DIR/scripts/unseal.sh"

cat <<MSG

==================================================================
 Vault inicializado y desellado.

 Root token:  $(jq -r .root_token "$INIT_FILE")

 IMPORTANTE:
  - Copia $INIT_FILE a un lugar seguro (gestor de contraseñas,
    cifrado offline...) y repártelo entre varias personas. Si lo
    pierdes, los datos de Vault son irrecuperables.
  - Este fichero NO debe quedarse en el servidor a largo plazo.
  - Siguiente paso: scripts/bootstrap.sh (audit, KV, políticas, usuario admin)
==================================================================
MSG
