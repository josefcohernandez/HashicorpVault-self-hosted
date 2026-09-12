#!/usr/bin/env bash
# Puesta en marcha completa de Vault + Traefik en un solo paso.
# Idempotente: se puede relanzar en cualquier momento; cada paso detecta si ya está hecho.
#
# Uso:  ./setup.sh
#
# Variables opcionales para ejecución no interactiva:
#   ADMIN_USER / ADMIN_PASSWORD   usuario administrador (bootstrap.sh)
#   SETUP_INSTALL_CRON=yes|no     instalar tareas cron de backup y rotación de audit
#   SETUP_DISABLE_SWAP=yes|no     desactivar el swap del host (requiere sudo)
#   SETUP_CERT_TIMEOUT=segundos   espera máxima al certificado de Let's Encrypt (por defecto 180)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

step() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
ask_yes_no() { # ask_yes_no "pregunta" "valor_por_defecto(s|n)" "VARIABLE_ENV"
  local q="$1" def="$2" preset="${3:-}" ans
  if [[ -n "$preset" ]]; then
    [[ "$preset" =~ ^([Yy]|[Ss]|yes|si|sí)$ ]]; return
  fi
  if [[ "$def" == "s" ]]; then read -rp "$q [S/n]: " ans; ans="${ans:-s}"; else read -rp "$q [s/N]: " ans; ans="${ans:-n}"; fi
  [[ "$ans" =~ ^([Yy]|[Ss]|yes|si|sí)$ ]]
}

# ---------------------------------------------------------------- 1. Requisitos
step "Comprobando requisitos"
for cmd in docker jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "Falta '$cmd' en el host." >&2; exit 1; }
done
docker compose version >/dev/null 2>&1 || { echo "Falta el plugin 'docker compose'." >&2; exit 1; }
docker info >/dev/null 2>&1 || { echo "No se puede hablar con el daemon de Docker (¿permisos del usuario?)." >&2; exit 1; }
echo "docker, docker compose y jq disponibles."

# ---------------------------------------------------------------- 2. Fichero .env
step "Configuración (.env)"
if [[ ! -f .env ]]; then
  cp .env.example .env
  chmod 600 .env
  echo "Creado .env a partir de .env.example."
fi

# Pide los valores obligatorios que sigan vacíos o con el placeholder
set_env_var() { # set_env_var CLAVE valor
  if grep -q "^$1=" .env; then
    sed -i "s|^$1=.*|$1=$2|" .env
  else
    printf '%s=%s\n' "$1" "$2" >> .env
  fi
}
get_env_var() { grep -E "^$1=" .env | head -1 | cut -d= -f2- || true; }

prompt_required() { # prompt_required CLAVE "descripción" "placeholder_a_ignorar"
  local key="$1" desc="$2" placeholder="${3:-}" cur val
  cur="$(get_env_var "$key")"
  if [[ -z "$cur" || "$cur" == "$placeholder" ]]; then
    while [[ -z "${val:-}" ]]; do read -rp "$desc: " val; done
    set_env_var "$key" "$val"
  fi
}
prompt_required VAULT_DOMAIN     "Dominio público de Vault (ej. vault.midominio.com)" "vault.example.com"
prompt_required ACME_EMAIL       "Email para Let's Encrypt"
prompt_required CF_DNS_API_TOKEN "Token de API de Cloudflare (Zone:DNS:Edit)"

# A partir de aquí usamos las funciones comunes de los scripts (requieren .env)
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/lib.sh"
echo "Dominio: $VAULT_DOMAIN"
[[ "${ACME_CA_SERVER:-}" == *staging* ]] && warn "ACME_CA_SERVER apunta a staging: el certificado no será de confianza para los navegadores."

# ---------------------------------------------------------------- 3. Arrancar
step "Arrancando contenedores"
"${COMPOSE[@]}" up -d

log "Esperando a que Vault responda..."
vault_health() { "${COMPOSE[@]}" ps --format '{{.Health}}' vault 2>/dev/null || true; }
for _ in $(seq 1 30); do
  [[ "$(vault_health)" == "healthy" ]] && break
  sleep 2
done
[[ "$(vault_health)" == "healthy" ]] || die "Vault no está sano. Revisa: docker compose logs vault"
log "Vault en ejecución (healthy)."

# ---------------------------------------------------------------- 4. Certificado
step "Certificado TLS"
https_port="$("${COMPOSE[@]}" port traefik 443 2>/dev/null | awk -F: '{print $NF}')"
cert_timeout="${SETUP_CERT_TIMEOUT:-180}"
issuer=""
if command -v openssl >/dev/null 2>&1 && [[ -n "$https_port" ]]; then
  log "Esperando al certificado de Let's Encrypt para $VAULT_DOMAIN (máx. ${cert_timeout}s)..."
  for ((i = 0; i < cert_timeout; i += 5)); do
    issuer="$(echo | openssl s_client -connect "127.0.0.1:$https_port" -servername "$VAULT_DOMAIN" 2>/dev/null \
              | openssl x509 -noout -issuer 2>/dev/null || true)"
    [[ "$issuer" == *"Let's Encrypt"* ]] && break
    sleep 5
  done
fi
if [[ "$issuer" == *"Let's Encrypt"* ]]; then
  log "Certificado emitido: $issuer"
else
  warn "Todavía no hay certificado de Let's Encrypt. Vault funciona igualmente; revisa 'docker compose logs traefik'"
  warn "(token de Cloudflare, registro DNS de $VAULT_DOMAIN, email ACME). Se reintenta solo."
fi

# ---------------------------------------------------------------- 5. Init / Unseal
step "Inicialización y desellado"
if ! is_initialized; then
  "$ROOT_DIR/scripts/init.sh"
elif is_sealed; then
  "$ROOT_DIR/scripts/unseal.sh"
else
  log "Vault ya está inicializado y desellado."
fi

# ---------------------------------------------------------------- 6. Bootstrap
step "Configuración inicial (audit, KV, políticas, usuario admin, token de backup)"
token_valid() { VAULT_TOKEN="$(root_token)" vault_exec token lookup >/dev/null 2>&1; }
if [[ -z "${VAULT_TOKEN:-}" && ! -f "$INIT_FILE" ]]; then
  warn "No hay token disponible (ni VAULT_TOKEN ni $INIT_FILE): se omite el bootstrap."
  warn "Si ya lo ejecutaste antes, no pasa nada. Si no, exporta VAULT_TOKEN y relanza."
elif ! token_valid; then
  if [[ -f "$BACKUP_TOKEN_FILE" ]]; then
    log "El root token ya está revocado y el bootstrap se hizo previamente: se omite."
  else
    die "El token disponible no es válido (¿root token revocado?). Exporta VAULT_TOKEN con un token admin y relanza."
  fi
else
  "$ROOT_DIR/scripts/bootstrap.sh"
fi

# ---------------------------------------------------------------- 7. Primer backup
step "Primer snapshot de Raft"
if [[ -f "$BACKUP_TOKEN_FILE" || -n "${VAULT_TOKEN:-}" ]]; then
  "$ROOT_DIR/scripts/backup.sh"
else
  warn "Sin token de backup: se omite el snapshot."
fi

# ---------------------------------------------------------------- 8. Cron
step "Tareas programadas"
cron_backup="0 3 * * * $ROOT_DIR/scripts/backup.sh >> $HOME/vault-backup.log 2>&1"
cron_audit="0 4 * * 0 $ROOT_DIR/scripts/rotate-audit.sh >> $HOME/vault-audit.log 2>&1"
if crontab -l 2>/dev/null | grep -qF "$ROOT_DIR/scripts/backup.sh"; then
  log "Las tareas cron ya están instaladas."
elif ask_yes_no "¿Instalar cron de backup diario (03:00) y rotación semanal del audit log (dom 04:00)?" s "${SETUP_INSTALL_CRON:-}"; then
  { crontab -l 2>/dev/null || true; echo "$cron_backup"; echo "$cron_audit"; } | crontab -
  log "Cron instalado. Revisa con: crontab -l"
else
  log "Cron no instalado. Líneas sugeridas:"; echo "  $cron_backup"; echo "  $cron_audit"
fi

# ---------------------------------------------------------------- 9. Swap
step "Swap del host"
if [[ -z "$(swapon --show --noheadings 2>/dev/null)" ]]; then
  log "El swap ya está desactivado."
elif ask_yes_no "Hay swap activo. Con disable_mlock la memoria de Vault podría volcarse a disco. ¿Desactivarlo de forma permanente (sudo)?" n "${SETUP_DISABLE_SWAP:-}"; then
  sudo swapoff -a && sudo sed -i.bak -E '/^[^#].*\sswap\s/s/^/#/' /etc/fstab && log "Swap desactivado (copia de /etc/fstab en /etc/fstab.bak)."
else
  warn "Swap activo. Puedes desactivarlo más tarde con: sudo swapoff -a  (y comentar la línea swap en /etc/fstab)"
fi

# ---------------------------------------------------------------- 10. Resumen
step "Resumen"
"$ROOT_DIR/scripts/vault.sh" status | grep -E 'Initialized|Sealed|Version|HA Mode' | sed 's/^/  /'
cat <<MSG

  UI:   https://${VAULT_DOMAIN}/ui   (método Username)
  CLI:  scripts/vault.sh login -method=userpass username=${ADMIN_USER:-admin}

  PENDIENTE DE TU PARTE:
   - Guarda $INIT_FILE fuera del servidor (gestor de contraseñas o soporte cifrado).
     Contiene las claves de unseal y el root token. Sin ellas los datos son irrecuperables.
   - Cuando compruebes que el usuario admin funciona, revoca el root token:
       VAULT_TOKEN=\$(jq -r .root_token $INIT_FILE) scripts/vault.sh token revoke -self
   - Tras cada reinicio del host o del contenedor: scripts/unseal.sh
   - Copia los snapshots de $BACKUP_DIR a otra máquina.
MSG
