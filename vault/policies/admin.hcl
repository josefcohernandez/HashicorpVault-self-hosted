# Política "admin": administración completa de Vault sin ser root.
# Basada en la recomendación de HashiCorp para operadores.

# Gestionar métodos de autenticación
path "auth/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "sys/auth/*" {
  capabilities = ["create", "update", "delete", "sudo"]
}
path "sys/auth" {
  capabilities = ["read"]
}

# Gestionar políticas ACL
path "sys/policies/acl/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "sys/policies/acl" {
  capabilities = ["list"]
}

# Gestionar motores de secretos
path "sys/mounts/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
path "sys/mounts" {
  capabilities = ["read", "list"]
}

# Acceso completo al motor KV v2 montado en secret/
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list", "patch"]
}

# Identidad (entidades, grupos, alias)
path "identity/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Gestionar tokens y leases
path "sys/leases/*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}

# Audit devices
path "sys/audit" {
  capabilities = ["read", "list"]
}
path "sys/audit/*" {
  capabilities = ["create", "read", "update", "delete", "sudo"]
}

# Estado del sistema, snapshots y utilidades
path "sys/health" {
  capabilities = ["read", "sudo"]
}
path "sys/capabilities" {
  capabilities = ["create", "update"]
}
path "sys/capabilities-self" {
  capabilities = ["create", "update"]
}
path "sys/storage/raft/*" {
  capabilities = ["read", "update", "sudo"]
}
path "sys/seal" {
  capabilities = ["update", "sudo"]
}
