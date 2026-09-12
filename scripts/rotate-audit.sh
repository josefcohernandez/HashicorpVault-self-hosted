#!/usr/bin/env bash
# Rota el audit log: renombra el fichero, envía SIGHUP a Vault para que lo reabra,
# comprime el antiguo y elimina los que superan AUDIT_RETENTION_DAYS.
# El log vive en el volumen vault_logs (/vault/logs dentro del contenedor).
# Ejemplo cron (semanal, domingo 04:00):
#   0 4 * * 0 /ruta/al/repo/scripts/rotate-audit.sh >> /var/log/vault-audit-rotate.log 2>&1
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_running

retention="${AUDIT_RETENTION_DAYS:-30}"
ts="$(date +%Y%m%d-%H%M%S)"

if ! "${COMPOSE[@]}" exec -T vault test -f /vault/logs/audit.log; then
  warn "No existe /vault/logs/audit.log (¿audit device no habilitado?). Nada que rotar."
  exit 0
fi

log "Rotando audit.log -> audit-$ts.log"
"${COMPOSE[@]}" exec -T vault mv /vault/logs/audit.log "/vault/logs/audit-$ts.log"
# dumb-init (PID 1) reenvía SIGHUP al proceso vault, que reabre el fichero de audit.
# Compose muestra "Killing/Killed" pero solo envía la señal: el contenedor NO se reinicia.
"${COMPOSE[@]}" kill -s HUP vault
sleep 2
"${COMPOSE[@]}" exec -T vault test -f /vault/logs/audit.log || die "Vault no ha recreado audit.log tras SIGHUP."

"${COMPOSE[@]}" exec -T vault gzip "/vault/logs/audit-$ts.log"
"${COMPOSE[@]}" exec -T vault find /vault/logs -name 'audit-*.log.gz' -mtime +"$retention" -delete
log "Rotación completada. Retención: $retention días."
