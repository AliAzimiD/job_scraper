# How to Revert Directory Organization

If you need to revert the directory organization for any reason, follow these steps:

## Immediate Reversion (Using Backup)

1. **Restore from Backup**:
   ```bash
   # Replace with your actual backup directory
   BACKUP_DIR="./pre_organization_backup_YYYYMMDD_HHMMSS"
   
   # Restore script files
   cp ${BACKUP_DIR}/*.sh .
   
   # Restore docker-compose files
   cp ${BACKUP_DIR}/docker-compose*.yml .
   ```

2. **Remove Symlinks**:
   ```bash
   rm cleanup.sh run-migrations.sh start-db.sh setup-db.sh setup-minimal.sh
   ```

## Manual Reversion

If you don't have a backup:

1. **Move Scripts Back**:
   ```bash
   mv scripts/*.sh .
   ```

2. **Move Docker Compose Files Back**:
   ```bash
   mv docker/*.yml .
   ```

3. **Move Archived Files Back**:
   ```bash
   mv archive/*.sh .
   ```

## Check Services After Reversion

After reverting, check if services are running correctly:

```bash
docker-compose ps
```

If services are not running properly, you may need to restart them:

```bash
docker-compose down
docker-compose up -d
```
