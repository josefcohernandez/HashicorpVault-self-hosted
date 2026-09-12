#!/usr/bin/env bash
# Wrapper del CLI de Vault dentro del contenedor. Ejemplos:
#   scripts/vault.sh status
#   scripts/vault.sh login -method=userpass username=admin
#   scripts/vault.sh kv put secret/app/db password=xyz
# Propaga VAULT_TOKEN del host si está definido.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
env_args=()
[[ -n "${VAULT_TOKEN:-}" ]] && env_args+=(-e "VAULT_TOKEN=$VAULT_TOKEN")
tty_args=()
[[ -t 0 ]] || tty_args+=(-T)
exec "${COMPOSE[@]}" exec "${tty_args[@]}" "${env_args[@]}" vault vault "$@"
