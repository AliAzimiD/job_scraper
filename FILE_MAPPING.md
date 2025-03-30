# File Mapping Reference

This document provides a mapping between the original file structure and the new organized structure. Use this as a reference when looking for files that have been moved.

## Script Files

| Original Location | New Location | Symlink Created |
|-------------------|--------------|----------------|
| `/root/karchi/job_scraper/cleanup.sh` | `/root/karchi/job_scraper/scripts/cleanup.sh` | Yes |
| `/root/karchi/job_scraper/run-migrations.sh` | `/root/karchi/job_scraper/scripts/run-migrations.sh` | Yes |
| `/root/karchi/job_scraper/start-db.sh` | `/root/karchi/job_scraper/scripts/start-db.sh` | Yes |
| `/root/karchi/job_scraper/setup-db.sh` | `/root/karchi/job_scraper/scripts/setup-db.sh` | Yes |
| `/root/karchi/job_scraper/setup-minimal.sh` | `/root/karchi/job_scraper/scripts/setup-minimal.sh` | Yes |
| `/root/karchi/job_scraper/docker_manage.sh` | `/root/karchi/job_scraper/scripts/docker_manage.sh` | No |
| `/root/karchi/job_scraper/install-fixed.sh` | `/root/karchi/job_scraper/archive/install-fixed.sh` | No |
| `/root/karchi/job_scraper/fresh-install.sh` | `/root/karchi/job_scraper/archive/fresh-install.sh` | No |
| `/root/karchi/job_scraper/complete-setup.sh` | `/root/karchi/job_scraper/archive/complete-setup.sh` | No |
| `/root/karchi/job_scraper/install.sh` | `/root/karchi/job_scraper/install.sh` (unchanged) | N/A |

## Docker Compose Files

| Original Location | New Location | Notes |
|-------------------|--------------|-------|
| `/root/karchi/job_scraper/docker-compose.yml` | `/root/karchi/job_scraper/docker-compose.yml` (unchanged) | Main file kept in root |
| `/root/karchi/job_scraper/docker-compose.dev.yml` | `/root/karchi/job_scraper/docker/docker-compose.dev.yml` | Development version |
| `/root/karchi/job_scraper/docker-compose.minimal.yml` | `/root/karchi/job_scraper/docker/docker-compose.minimal.yml` | Minimal setup |
| `/root/karchi/job_scraper/migrations/docker-compose.updated.yml` | `/root/karchi/job_scraper/docker/docker-compose.updated.yml` | Copy kept in both locations |
| `/root/karchi/job_scraper/migrations/simplified-compose.yml` | `/root/karchi/job_scraper/docker/simplified-compose.yml` | Copy kept in both locations |

## Directory Structure Reference

```
job_scraper/
├── archive/             # Archived/outdated files
│   ├── complete-setup.sh
│   ├── fresh-install.sh
│   ├── install-fixed.sh
│   └── install.sh.bak
│
├── backups/             # Database backups
│   ├── jobsdb_backup_*.sql
│   └── README.md
│
├── config/              # Configuration files
│
├── docker/              # Docker configurations
│   ├── docker-compose.dev.yml
│   ├── docker-compose.minimal.yml
│   ├── docker-compose.updated.yml
│   ├── simplified-compose.yml
│   └── README.md
│
├── init-db/             # Database initialization
│   ├── 01-init.sql
│   └── 02-schema-update.sh
│
├── job_data/            # Scraped job data
│
├── migrations/          # Migration scripts
│   ├── *.sql
│   ├── *.py
│   └── README.md
│
├── scripts/             # Utility scripts
│   ├── cleanup.sh
│   ├── docker_manage.sh
│   ├── run-migrations.sh
│   ├── setup-db.sh
│   ├── setup-minimal.sh
│   ├── start-db.sh
│   └── README.md
│
├── secrets/             # Secret files
│
├── src/                 # Source code
│
├── superset/            # Superset config
│   ├── Dockerfile
│   └── superset_config.py
│
├── docker-compose.yml   # Main Docker Compose file
├── install.sh           # Main installation script
├── organize.sh          # Organization script
├── FILE_MAPPING.md      # This file
├── ORGANIZATION.md      # Organization strategy
├── README.md            # Main documentation
├── REVERT_ORGANIZATION.md # Reversion instructions
└── SAFETY_CHECKS.md     # Safety considerations
```

## How to Use This Reference

When looking for a file that has been moved:

1. Check this mapping document to find its new location
2. For scripts with symlinks, you can still run them from the original path
3. For Docker Compose files, use the `-f` flag to specify the new path:
   ```bash
   docker-compose -f docker/docker-compose.dev.yml up -d
   ```

## Git Considerations

If you're using Git and need to find the history of a moved file:

```bash
git log --follow -- scripts/cleanup.sh  # Will show history including before the move
``` 