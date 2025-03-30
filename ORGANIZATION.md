# Directory Organization

This document explains the organization of the Job Scraper project directory.

## Changes Made

1. **Created Organization Directories**:
   - `archive/` - For older/outdated files
   - `scripts/` - For utility scripts
   - `docker/` - For Docker-related files

2. **Prepared Organization Scripts**:
   - `organize.sh` - Script to finalize the directory organization

3. **Added Documentation**:
   - Added README files in each directory explaining its purpose
   - Updated main README.md with directory structure information
   - Added backup information in `backups/README.md`

## Directory Structure

The project is now organized with the following directory structure:

```
job_scraper/
├── archive/            # Archived/outdated files
├── backups/            # Database backups
├── config/             # Configuration files
├── docker/             # Docker Compose configurations
├── init-db/            # Database initialization scripts
├── job_data/           # Scraped job data
├── migrations/         # Database migration scripts
├── scripts/            # Utility scripts
├── secrets/            # Secret files
├── src/                # Source code
├── superset/           # Superset configuration
├── docker-compose.yml  # Main Docker Compose file
├── install.sh          # Main installation script
├── organize.sh         # Organization script
└── README.md           # Main documentation
```

## How to Apply the Changes

To apply the directory organization permanently, run:

```bash
cd /root/karchi/job_scraper
./organize.sh
```

The script will:
1. Move installation scripts to appropriate directories
2. Move Docker Compose files to the docker directory
3. Move utility scripts to the scripts directory
4. Create symlinks for frequently used scripts

## Impact on Running Services

The organization changes will NOT affect running services because:

1. The main `docker-compose.yml` remains unchanged in the root directory
2. Symlinks are created for common scripts, maintaining the original paths
3. Only duplicate or auxiliary files are moved to organization directories

## Recommended Workflow After Organization

After applying the organization:

1. Use `./install.sh` for full installation (this is the improved version)
2. Use the scripts in `scripts/` directory for maintenance tasks
3. Use the configs in `docker/` directory for alternative deployments
4. Check `backups/` for database backups and follow the backup retention policy

## Benefits of Organization

This organization provides several benefits:

1. **Improved Maintainability**: Clear separation of concerns
2. **Better Documentation**: Each directory has its own README
3. **Reduced Clutter**: Similar files are grouped together
4. **Easier Backups**: Clear backup strategy and location
5. **Simpler Deployment**: Single main installation script 