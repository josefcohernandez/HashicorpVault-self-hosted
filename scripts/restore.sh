#!/usr/bin/env bash
# Restaura un snapshot de Raft creado por scripts/backup.sh.
# ATENCIÓN: sobrescribe TODO el estado actual de Vault (secretos, políticas, tokens...).
# Uso: scripts/restore.sh backups/vault-YYYYmmdd-HHMMSS.snap
# Si el snapshot procede de otra instalación, tras restaurar Vault queda sellado y
# necesita las claves de unseal de ESA instalación (no las de secrets/vault-init.json).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require jq
ensure_running

file="${1:?Uso: $0 <fichero.snap>}"
[[ -s "$file" ]] || die "No existe o está vacío: $file"
is_sealed && die "Vault está sellado. Ejecuta scripts/unseal.sh antes de restaurar."

export VAULT_TOKEN
VAULT_TOKEN="$(root_token)"

warn "Vas a sobrescribir todos los datos de Vault con $file"
read -rp "Escribe RESTAURAR para continuar: " confirm
[[ "$confirm" == "RESTAURAR" ]] || die "Cancelado."

log "Copiando snapshot al contenedor..."
"${COMPOSE[@]}" exec -T vault sh -c 'cat > /tmp/restore.snap' < "$file"
log "Restaurando..."
vault_exec operator raft snapshot restore -force /tmp/restore.snap
"${COMPOSE[@]}" exec -T vault rm -f /tmp/restore.snap

if wait_unsealed 10; then
  log "Restauración completada. Vault sigue desellado."
else
  warn "Restauración completada. Vault ha quedado sellado: ejecuta scripts/unseal.sh con las claves del cluster de origen del snapshot."
fi
