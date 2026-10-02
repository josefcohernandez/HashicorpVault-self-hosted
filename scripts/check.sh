#!/usr/bin/env bash
# Verificación completa del proyecto: lo mismo en local (antes de abrir el PR) y en CI.
# Sin Vault, sin Cloudflare y sin secretos: sintaxis y lint de los scripts y el compose renderizado
# con valores de prueba. Arrancar Vault de verdad (setup.sh) sigue siendo prueba manual.
set -euo pipefail
cd "$(dirname "$0")/.."

paso() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }

paso "Sintaxis de los scripts de shell"
git ls-files -z '*.sh' '.githooks/*' | xargs -0 -r -n1 bash -n

paso "shellcheck"
# SC1090: lib.sh carga el .env, que no existe en el repo. SC2034: lib.sh define variables para
# los scripts que lo cargan. La imagen fijada da el mismo resultado en local y en la CI.
mapfile -d '' scripts < <(git ls-files -z '*.sh' '.githooks/*')
docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.10.0 \
  -x -S warning -e SC1090,SC2034 "${scripts[@]}"

paso "docker compose config"
VAULT_DOMAIN=vault.ci.example ACME_EMAIL=ci@example.com CF_DNS_API_TOKEN=ci \
  docker compose --env-file .env.example config -q

echo
echo "check.sh: todo bien"
