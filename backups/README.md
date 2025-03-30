# Database Backups

This directory contains PostgreSQL database backups for the Job Scraper system.

## Backup Format

Backup files follow the naming convention:
```
jobsdb_backup_YYYYMMDD_HHMMSS.sql
```

Where:
- `YYYYMMDD` is the date (e.g., 20250327)
- `HHMMSS` is the time (e.g., 141544)

## Creating Backups

To create a new backup:

```bash
# From the project root
cd /root/karchi/job_scraper
docker exec -t job_db pg_dump -U jobuser jobsdb > backups/jobsdb_backup_$(date +%Y%m%d_%H%M%S).sql
```

## Restoring Backups

To restore a backup:

```bash
# Replace with your backup file
BACKUP_FILE="backups/jobsdb_backup_20250327_150411.sql"

# Restore to database
cat $BACKUP_FILE | docker exec -i job_db psql -U jobuser -d jobsdb
```

## Backup Retention Policy

- Keep the most recent full backup from each month
- For the current month, keep the most recent backup from each week
- Remove older backups to save disk space

## Automated Backups

The Job Scraper system includes automatic daily backups when CRON is enabled in the configuration.

These backups are stored in this directory with the same naming convention. 