#!/usr/bin/env bash
# Snapshot del almacenamiento Raft a ./backups/vault-<fecha>.snap con retención.
# Usa el token de secrets/backup.token (creado por bootstrap.sh) o VAULT_TOKEN.
# Pensado para cron. Ejemplo (diario a las 03:00):
#   0 3 * * * /ruta/al/repo/scripts/backup.sh >> /var/log/vault-backup.log 2>&1
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require jq
ensure_running
is_sealed && die "Vault está sellado, no se puede hacer snapshot."

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  [[ -f "$BACKUP_TOKEN_FILE" ]] || die "No existe $BACKUP_TOKEN_FILE. Ejecuta scripts/bootstrap.sh o exporta VAULT_TOKEN."
  VAULT_TOKEN="$(<"$BACKUP_TOKEN_FILE")"
fi
export VAULT_TOKEN

retention="${BACKUP_RETENTION_DAYS:-14}"
ts="$(date +%Y%m%d-%H%M%S)"
target="$BACKUP_DIR/vault-$ts.snap"
tmp_in_container="/tmp/vault-$ts.snap"

# Renovar el token periódico para que no caduque entre ejecuciones
vault_exec token renew >/dev/null 2>&1 || warn "No se pudo renovar el token de backup (¿no es periódico?)"

log "Creando snapshot..."
vault_exec operator raft snapshot save "$tmp_in_container"
umask 077
"${COMPOSE[@]}" exec -T vault cat "$tmp_in_container" > "$target"
"${COMPOSE[@]}" exec -T vault rm -f "$tmp_in_container"

[[ -s "$target" ]] || die "El snapshot $target está vacío."
log "Snapshot guardado: $target ($(du -h "$target" | cut -f1))"

deleted="$(find "$BACKUP_DIR" -maxdepth 1 -name 'vault-*.snap' -mtime +"$retention" -print -delete | wc -l)"
[[ "$deleted" -gt 0 ]] && log "Eliminados $deleted snapshots con más de $retention días."

log "Restaurar con: scripts/restore.sh $target"
