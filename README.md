# HashiCorp Vault en Docker

Despliegue de **HashiCorp Vault 2.1.0** en un solo nodo con almacenamiento integrado
(Raft), detrás de **Traefik 3.7** que obtiene certificados de Let's Encrypt mediante
el reto DNS-01 con Cloudflare.

```
Internet ──443──▶ Traefik (TLS Let's Encrypt) ──HTTP red interna──▶ Vault :8200
                                                                       │
                                                             volumen vault_data (Raft)
                                                             volumen vault_logs (audit)
```

## Estructura

```
.
├── setup.sh                  Puesta en marcha completa en un solo paso (idempotente)
├── docker-compose.yml        Servicios traefik y vault, red vault_proxy, volúmenes
├── .env.example              Plantilla de variables (copiar a .env)
├── vault/
│   ├── config/vault.hcl      Configuración del servidor Vault
│   └── policies/
│       ├── admin.hcl         Política de administrador (sin ser root)
│       └── backup.hcl        Política mínima para snapshots
├── traefik/
│   └── dynamic/tls.yml       Opciones TLS y cabeceras de seguridad
├── scripts/
│   ├── init.sh               Inicializa Vault (claves Shamir + root token) y lo desella
│   ├── unseal.sh             Desella Vault tras cada reinicio
│   ├── bootstrap.sh          Audit, KV v2, políticas, userpass, token de backup
│   ├── backup.sh             Snapshot Raft a ./backups con retención (para cron)
│   ├── restore.sh            Restaura un snapshot
│   ├── rotate-audit.sh       Rota y comprime el audit log (para cron)
│   ├── vault.sh              Wrapper del CLI: scripts/vault.sh <comando>
│   └── lib.sh                Funciones comunes
├── secrets/                  Claves de unseal y tokens (ignorado por git)
└── backups/                  Snapshots (ignorado por git)
```

## Requisitos

- Docker 24+ y Docker Compose v2 (probado con Docker 29.8 y Compose v5.5).
- `jq` en el host (lo usan los scripts).
- Un dominio gestionado en Cloudflare y un token de API con permisos
  `Zone:DNS:Edit` y `Zone:Zone:Read` sobre esa zona.
- Puertos 80 y 443 libres en el host. El 80 solo se usa para redirigir a HTTPS
  (el reto DNS-01 no lo necesita).

## Puesta en marcha rápida

```bash
./setup.sh
```

Un solo comando hace todo el proceso y es idempotente (puedes relanzarlo cuando
quieras): comprueba requisitos, crea `.env` preguntando lo que falte, arranca los
contenedores, espera al healthcheck y al certificado, inicializa o desella Vault
según su estado, ejecuta el bootstrap, hace el primer snapshot y ofrece instalar
el cron y desactivar el swap. Para ejecutarlo sin preguntas:

```bash
ADMIN_PASSWORD='...' SETUP_INSTALL_CRON=yes SETUP_DISABLE_SWAP=no ./setup.sh
```

Al terminar, guarda `secrets/vault-init.json` fuera del servidor y, cuando
compruebes que el usuario admin funciona, revoca el root token.

## Puesta en marcha paso a paso

Equivale a lo que hace `setup.sh`, por si prefieres controlar cada fase.

1. **Configura las variables**

   ```bash
   cp .env.example .env
   nano .env   # VAULT_DOMAIN, ACME_EMAIL, CF_DNS_API_TOKEN
   ```

   Mientras pruebas, usa el servidor ACME de staging (comentado en `.env.example`)
   para no agotar los límites de emisión de Let's Encrypt. Cuando el certificado
   de staging se emita correctamente, vuelve al de producción y borra el volumen
   `traefik_acme` (`docker volume rm vault_traefik_acme`) para forzar la reemisión.

2. **Crea el registro DNS** `VAULT_DOMAIN` apuntando a la IP pública del host.

3. **Arranca los contenedores**

   ```bash
   docker compose up -d
   docker compose logs -f traefik   # espera a ver el certificado emitido
   ```

4. **Inicializa Vault** (solo la primera vez)

   ```bash
   scripts/init.sh
   ```

   Genera 5 claves de unseal (umbral 3) y el root token en
   `secrets/vault-init.json`, y desella Vault. **Guarda ese fichero en un lugar
   seguro y bórralo del servidor.** Sin las claves, los datos son irrecuperables.

5. **Configuración inicial**

   ```bash
   scripts/bootstrap.sh
   ```

   Habilita el audit log, el motor KV v2 en `secret/`, las políticas `admin` y
   `backup`, el método `userpass` con un usuario administrador (pide la
   contraseña) y crea el token que usa `backup.sh`. Es idempotente.

6. **Accede**: `https://<VAULT_DOMAIN>/ui` con método *Username*, o desde CLI:

   ```bash
   scripts/vault.sh login -method=userpass username=admin
   scripts/vault.sh kv put secret/app/db password=xyz
   ```

7. **Revoca el root token** cuando todo funcione. Si lo necesitas de nuevo, se
   regenera con las claves de unseal (`vault operator generate-root`).

## Operación diaria

| Tarea | Comando |
|---|---|
| Estado | `scripts/vault.sh status` |
| Desellar tras un reinicio | `scripts/unseal.sh` |
| Backup manual | `scripts/backup.sh` |
| Restaurar | `scripts/restore.sh backups/vault-<fecha>.snap` |
| Rotar audit log | `scripts/rotate-audit.sh` |
| Ver audit log | `docker compose exec vault tail -f /vault/logs/audit.log` |
| Logs del servidor | `docker compose logs -f vault` |

**Vault queda sellado tras cada reinicio del contenedor o del host.** Es el
comportamiento esperado con claves Shamir. `unseal.sh` usa
`secrets/vault-init.json` si existe; si no, pide las claves por teclado.

### Cron sugerido

```cron
# Snapshot diario y rotación semanal del audit log
0 3 * * * /ruta/al/repo/scripts/backup.sh       >> /var/log/vault-backup.log 2>&1
0 4 * * 0 /ruta/al/repo/scripts/rotate-audit.sh >> /var/log/vault-audit.log  2>&1
```

Copia los ficheros de `backups/` fuera del host (los snapshots están cifrados
con la clave maestra de Vault, pero siguen necesitando las claves de unseal
para ser útiles).

## Actualizar Vault

1. Haz un snapshot: `scripts/backup.sh`.
2. Cambia la etiqueta de la imagen en `docker-compose.yml` (consulta primero las
   notas de la versión en https://developer.hashicorp.com/vault/docs/updates/important-changes).
3. `docker compose pull && docker compose up -d`.
4. `scripts/unseal.sh`.

## Decisiones de diseño

- **TLS solo en Traefik.** Vault escucha en HTTP (`tls_disable = true`) en la
  red interna de Docker `vault_proxy` y no publica ningún puerto al host. El
  tráfico Traefik→Vault viaja en claro únicamente dentro de esa red.
- **`x_forwarded_for_authorized_addrs`** acepta las redes privadas para que el
  audit log registre la IP real del cliente que llega a través de Traefik.
- **`disable_mlock = true`**, recomendado por HashiCorp con Raft. Desactiva el
  swap en el host (`swapoff -a`) para que la memoria de Vault no acabe en disco.
  Desde Vault 2.0.2 la imagen ya no necesita la capability `IPC_LOCK`.
- **Volúmenes con nombre** para datos y logs. La imagen corre como usuario
  `vault` (uid 100), y los volúmenes con nombre heredan esos permisos sin
  necesidad de `chown` en el host. La configuración y las políticas se montan
  en solo lectura desde el repositorio.
- **Healthcheck tolerante:** `/v1/sys/health?sealedcode=204&uninitcode=204`.
  Traefik deja de enrutar a contenedores *unhealthy*; si el healthcheck fallara
  con Vault sellado, no podrías desellarlo desde la UI.
- **`sniStrict: true`** en Traefik: rechaza conexiones TLS cuyo SNI no coincida
  con un certificado emitido. Evita servir el certificado por defecto a
  escáneres por IP.
- **Token de backup periódico** (30 días, se renueva en cada ejecución) con la
  política mínima `backup`, para no usar el root token en cron.

## Problemas frecuentes

- **`curl` a HTTPS falla con error de handshake TLS.** Todavía no hay
  certificado (mira `docker compose logs traefik`). Con `sniStrict: true` no se
  sirve el certificado por defecto. Causas habituales: token de Cloudflare sin
  permisos, registro DNS inexistente o `ACME_EMAIL` inválido.
- **`403 permission denied` justo después de restaurar un snapshot.** Los tokens
  creados después del snapshot no existen en el estado restaurado. Vuelve a
  hacer login.
- **`docker compose kill -s HUP` muestra "Killed".** Es solo el mensaje de
  Compose al enviar la señal; `rotate-audit.sh` no reinicia el contenedor.
- **Cambié `VAULT_DOMAIN`.** Ejecuta `docker compose up -d` para recrear el
  contenedor de Vault (`VAULT_API_ADDR` y la regla de Traefik dependen de él).

## Referencias

- Notas de la versión 2.1: https://developer.hashicorp.com/vault/docs/updates/release-notes
- Configuración del servidor: https://developer.hashicorp.com/vault/docs/configuration
- Almacenamiento integrado (Raft): https://developer.hashicorp.com/vault/docs/configuration/storage/raft
- Imagen Docker: https://hub.docker.com/r/hashicorp/vault
- Traefik ACME DNS-01: https://doc.traefik.io/traefik/https/acme/#dnschallenge
