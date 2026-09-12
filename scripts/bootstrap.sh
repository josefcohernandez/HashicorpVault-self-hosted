#!/usr/bin/env bash
# Configuración inicial tras el init:
#   - Audit device a fichero (/vault/logs/audit.log)
#   - Motor KV v2 en secret/
#   - Políticas admin y backup
#   - Auth userpass con un usuario administrador
#   - Token periódico para scripts/backup.sh
# Es idempotente: puede ejecutarse varias veces sin duplicar nada.
#
# Variables opcionales: ADMIN_USER (por defecto "admin"), ADMIN_PASSWORD (si no, se pide por teclado)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require jq
ensure_running
is_initialized || die "Vault no está inicializado. Ejecuta scripts/init.sh"
is_sealed && die "Vault está sellado. Ejecuta scripts/unseal.sh"

export VAULT_TOKEN
VAULT_TOKEN="$(root_token)"

# --- Audit ---------------------------------------------------------------
if vault_exec audit list -format=json | jq -e 'has("file/")' >/dev/null; then
  log "Audit device 'file/' ya habilitado."
else
  log "Habilitando audit device a /vault/logs/audit.log"
  vault_exec audit enable file file_path=/vault/logs/audit.log
fi

# --- KV v2 ---------------------------------------------------------------
if vault_exec secrets list -format=json | jq -e 'has("secret/")' >/dev/null; then
  log "Motor KV en secret/ ya habilitado."
else
  log "Habilitando motor KV v2 en secret/"
  vault_exec secrets enable -path=secret -version=2 kv
fi

# --- Políticas -----------------------------------------------------------
log "Escribiendo políticas admin y backup"
vault_exec policy write admin  /vault/policies/admin.hcl
vault_exec policy write backup /vault/policies/backup.hcl

# --- userpass + usuario admin ---------------------------------------------
if vault_exec auth list -format=json | jq -e 'has("userpass/")' >/dev/null; then
  log "Auth userpass ya habilitado."
else
  log "Habilitando auth userpass"
  vault_exec auth enable userpass
fi

admin_user="${ADMIN_USER:-admin}"
if vault_exec read "auth/userpass/users/$admin_user" >/dev/null 2>&1; then
  log "El usuario '$admin_user' ya existe. No se modifica la contraseña."
else
  if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
    read -rsp "Contraseña para el usuario '$admin_user': " ADMIN_PASSWORD; echo
    read -rsp "Repite la contraseña: " confirm; echo
    [[ "$ADMIN_PASSWORD" == "$confirm" ]] || die "Las contraseñas no coinciden."
  fi
  [[ ${#ADMIN_PASSWORD} -ge 12 ]] || die "La contraseña debe tener al menos 12 caracteres."
  log "Creando usuario '$admin_user' con política admin"
  # La contraseña se pasa por stdin (password=-) para que no aparezca en la lista de procesos
  printf '%s' "$ADMIN_PASSWORD" | vault_exec_stdin write "auth/userpass/users/$admin_user" \
    password=- token_policies=admin token_ttl=1h token_max_ttl=8h
fi

# --- Token para backups ---------------------------------------------------
if [[ -f "$BACKUP_TOKEN_FILE" ]]; then
  log "Token de backup ya existe en $BACKUP_TOKEN_FILE"
else
  log "Creando token periódico (30 días, renovable) para scripts/backup.sh"
  umask 077
  vault_exec token create -policy=backup -orphan -period=720h \
    -display-name=backup -format=json | jq -r '.auth.client_token' > "$BACKUP_TOKEN_FILE"
  chmod 600 "$BACKUP_TOKEN_FILE"
fi

cat <<MSG

==================================================================
 Bootstrap completado.

  UI:        https://${VAULT_DOMAIN}/ui  (método Username)
  Usuario:   $admin_user
  CLI:       scripts/vault.sh login -method=userpass username=$admin_user

 Recomendaciones:
  - Opera con el usuario admin, no con el root token.
  - Cuando todo funcione, revoca el root token:
      scripts/vault.sh token revoke <root_token>
    (se puede regenerar con las claves de unseal: vault operator generate-root)
  - Programa scripts/backup.sh en cron (ver README.md).
==================================================================
MSG
