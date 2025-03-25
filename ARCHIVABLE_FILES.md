# Job Scraper Project - Archivable Files

This document outlines the files and directories in the Job Scraper project that can be archived without affecting core functionality. These items are either temporary, redundant, development-only, or simply not required for the production application.

## Archiving Strategy

The `archive_unused_files.sh` script safely moves these files to an `archived_files` directory and compresses them into a timestamped archive. This preserves the files for future reference while cleaning up the main project directory.

## Categories of Archivable Files

### 1. Temporary Development Files

These files were created during development and are no longer needed for production:

- `fix_*.py`, `fix_*.sh` - Temporary fix scripts
- `fixed_*.py`, `fixed_*.html` - Fixed versions of files
- `final_*.py` - Final versions preserved elsewhere in the codebase
- `test_*.py` (outside tests directory) - Ad-hoc test scripts
- Temporary script files like `upload_features.sh`, `deploy_vps.sh`
- `ter` - Appears to be a misnamed or temporary file

### 2. Development Documentation

Documentation that has been consolidated into the main README or PROJECT_ORGANIZATION document:

- `README_IDE_SETUP.md`  
- `MONITORING.md`
- `PRODUCTION_SETUP.md`
- `RUNNING_LOCALLY.md`
- `WEB_INTERFACE_GUIDE.md`

### 3. Log Files

Old log files can be archived as they're not needed for ongoing operations:

- `logs/web_app.log`
- `logs/ConfigManager.log`
- `logs/DataManager.log`
- `logs/DatabaseManager.log`

### 4. Export Files

Job data exports are stored in the uploads directory and can be archived:

- `uploads/job_export_*.json`
- `uploads/job_export_*.csv`

### 5. Database Dumps

Database backups can be archived but preserved for reference:

- `jobsdb_backup.dump`
- `jobsdb_current_backup_*.dump`
- `database_schema.sql`

### 6. Non-Essential Directories

These directories are not required for core application functionality:

- `monitoring_docs/` - Documentation for monitoring setup
- `superset/`, `grafana/`, `prometheus/` - Optional monitoring services
- `docker/monitoring/` - Docker configurations for monitoring
- `docs/` - Additional documentation
- `backups/` - Old backups
- `src/` - Legacy code replaced by the `app/` directory
- `.vscode/` - IDE-specific settings
- `.pytest_cache/` - Test cache
- `job_scraper.egg-info/` - Build artifacts
- `job_data/` - Old data storage directory

### 7. Test Directories

Non-essential test directories (unit tests are preserved):

- `tests/integration/`
- `tests/e2e/`

### 8. Cache Files

Python cache directories that should be removed:

- `__pycache__/` directories throughout the codebase

### 9. Old Archive Files

Previous archive files that have been superseded:

- `job_scraper_archive_20250325_140913.tar.gz`

## Verification Process

After archiving, the following verification steps should be performed:

1. **Core Files Check**
   - Verify that `app/` directory contains all essential modules
   - Ensure `config/` directory contains all configuration files
   - Confirm `main.py` and `requirements.txt` are present

2. **Functionality Test**
   - Run the application with `python main.py`
   - Test that the scraper works correctly
   - Verify the web interface loads properly

3. **Archive Backup**
   - Keep the compressed archive file for reference
   - Remove the `archived_files` directory after confirming everything works

## Note on Essential Files

The following core components must NOT be archived:

- `app/` - Main application package with core functionality
- `config/` - Configuration files
- `main.py` - Entry point
- `requirements.txt` - Dependencies
- `docker-compose.yml` - Main Docker composition
- `Dockerfile` - Main application container
- `setup.sh` - Main setup script
- `README.md` - Main documentation
- `.env.example` - Environment variable template

## Conclusion

By archiving the files and directories listed in this document, the Job Scraper project can be streamlined to focus on essential functionality while preserving all important components for future reference.
