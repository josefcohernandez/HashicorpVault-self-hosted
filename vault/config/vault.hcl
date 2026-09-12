# Configuración del servidor Vault (modo servidor, un solo nodo, almacenamiento integrado Raft)
# Documentación: https://developer.hashicorp.com/vault/docs/configuration

ui           = true
cluster_name = "vault"
log_level    = "info"
log_format   = "standard"

# Recomendado por HashiCorp con Raft (usa ficheros mapeados en memoria).
# Desactiva el swap en el host para no volcar memoria de Vault a disco.
disable_mlock = true

# api_addr y cluster_addr se definen por variables de entorno en docker-compose.yml
# (VAULT_API_ADDR y VAULT_CLUSTER_ADDR) para poder usar el dominio del fichero .env.

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "0.0.0.0:8201"

  # Traefik termina TLS y habla HTTP con Vault por la red interna de Docker.
  # Vault no publica el puerto 8200 al exterior.
  tls_disable = true

  # Confiar en X-Forwarded-For solo desde redes privadas (donde vive Traefik),
  # para que los audit logs registren la IP real del cliente.
  x_forwarded_for_authorized_addrs   = ["10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"]
  x_forwarded_for_reject_not_present = false
  x_forwarded_for_hop_skips          = 0

  # Endpoint /v1/sys/metrics sin autenticación (Prometheus). Cámbialo a true si no lo usas.
  telemetry {
    unauthenticated_metrics_access = false
  }
}

storage "raft" {
  path    = "/vault/file"
  node_id = "vault-1"
}

telemetry {
  disable_hostname          = true
  prometheus_retention_time = "24h"
}
