# Política "backup": solo puede descargar snapshots de Raft.
# La usa scripts/backup.sh con un token periódico creado por scripts/bootstrap.sh.
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
