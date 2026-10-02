# HashicorpVault-self-hosted

<!-- Este fichero se carga en cada sesión: solo lo que Claude no puede deducir del código.
     Menos de 200 líneas. Cada línea pasa la prueba "si la quito, ¿se equivocaría?". -->

Proceso: metodología común (`~/.claude/metodologia/METODOLOGIA.md`). Todo entra por PR desde un
worktree (`flujo abrir <issue>`), con título `tipo: descripción` en español.

## Qué es

HashiCorp Vault de un solo nodo (Raft) detrás de su propio Traefik con Let's Encrypt por DNS-01 en
Cloudflare, más los scripts de operación (`setup.sh`, init, unseal, bootstrap, backup, restore).
No es instalable con `dockers` (no tiene `deploy/`): se despliega clonando el repo y con `./setup.sh`.
Las releases son solo tag y notas del CHANGELOG (`flujo publicar X.Y.Z`).

## Comandos

- Verificación completa (la misma que la CI): `scripts/check.sh` (bash -n, shellcheck en Docker y
  `docker compose config` con valores de prueba).
- Puesta en marcha idempotente: `./setup.sh`. CLI de Vault: `scripts/vault.sh <comando>`.

## Gotchas

- Publica 80 y 443 en el host con su propio Traefik y `container_name` fijos (`traefik`, `vault`):
  choca con myhomelab si comparten máquina (myhomelab trae su propio servicio `vault`).
- `secrets/` (claves de unseal y tokens) y `backups/` están en `.gitignore`: nunca se versionan ni
  se copian a la conversación. `.env` lo rellena el dueño.
- Probar `setup.sh` de verdad necesita dominio en Cloudflare y token: no se hace en la CI.
- Las decisiones de diseño viven en README, «Decisiones de diseño».

## Decisiones vigentes

<!-- Una línea por ADR: - [0001 · Título](docs/adr/0001-titulo.md): resumen en una frase. -->
