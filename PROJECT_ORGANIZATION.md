# Job Scraper Project Organization

This document outlines the project structure of the Job Scraper application, explaining which files and directories are essential for core functionality and which can be archived or removed.

## Essential Components

These components are required for the application to function properly:

### Core Application Files

- `main.py` - The main entry point for the application
- `requirements.txt` - Python dependencies
- `.env.example` - Template for environment variables (should be copied to `.env` with proper values)
- `README.md` - Main documentation
- `setup.sh` - Main setup script for application initialization

### Directory Structure

- `app/` - Main application package
  - `__init__.py` - Application factory and initialization
  - `core/` - Core business logic
    - `scraper.py` - Main scraper implementation
    - `exceptions.py` - Custom exception classes
  - `web/` - Web interface components
    - `routes.py` - URL routes and view functions
    - `filters.py` - Template filters
    - `views/` - View functions organized by feature
  - `db/` - Database-related components
    - `models.py` - SQLAlchemy models
    - `manager.py` - Database connection management
    - `migrations/` - Database migration scripts
  - `monitoring/` - Monitoring and metrics
    - `health.py` - Health check endpoints
    - `metrics.py` - Prometheus metrics
  - `utils/` - Utility functions
    - `config.py` - Configuration management
    - `log_setup.py` - Logging setup
    - `cache.py` - Redis cache utilities
  - `templates/` - HTML templates
    - `base.html` - Base template for all pages
    - `dashboard.html`, `status.html`, etc. - Page templates
    - `errors/` - Error page templates
  - `static/` - Static assets
    - `css/` - Stylesheet files
    - `js/` - JavaScript files
    - `img/` - Image files

- `config/` - Configuration files
  - `api_config.yaml` - API configuration
  - `logging_config.yaml` - Logging configuration
  - `app_config.yaml` - Application settings

- `uploads/` - Directory for uploaded files and exports

- `tests/` - Essential test files (unit tests)
  - `unit/` - Unit tests for application components

### Docker and Deployment

- `docker-compose.yml` - Main Docker Compose configuration
- `Dockerfile` - Main application Dockerfile

### Database

- `init-db/` - Database initialization scripts
  - SQL scripts for table creation and initial data setup

## Non-Essential Components (Safe to Archive)

These components can be archived or removed in a production environment:

### Development and Testing

- Test scripts: `test_app.py`, `test_export.py`, etc.
- Integration and E2E tests: `tests/integration/`, `tests/e2e/`
- Development Dockerfiles: `Dockerfile.dev`
- Development Docker Compose: `docker-compose.dev.yml`

### Temporary Files

- Fixed/updated versions of files: `fixed_*.html`, `fixed_*.py`, etc.
- Sample pages: `*_sample.html`
- Temporary scripts: `*_vps.py`, `*_vps.sh`

### Deployment Scripts

- VPS deployment: `deploy_*.sh`, `upload_*.sh`
- Setup scripts: `setup_*.sh` (except main `setup.sh`)
- Fix scripts: `fix_*.sh`, `fix_*.py`

### Monitoring Setup (Optional)

- `grafana/` - Grafana dashboards and configuration
- `prometheus/` - Prometheus configuration
- `docker/monitoring/` - Docker configurations for monitoring services
- Monitoring setup scripts: `*_monitoring.sh`

### Database Utilities

- Database dumps: `*.dump`
- Import/backup scripts: `import_*.sh`, `backup_*.sh`

### Legacy Code

- `src/` - Legacy source code replaced by the `app/` package

### Documentation

- Markdown files: `*_SETUP.md`, `*_GUIDE.md` (consolidate into main README)
- `docs/` - Additional documentation (consider moving essential information to README)
- `monitoring_docs/` - Monitoring documentation

## Archiving Process

To archive non-essential components:

1. Use the provided `archive_unused_files.sh` script to move non-essential files to an archive.
2. Verify that the application still works correctly after archiving:
   - Run the application locally: `python main.py`
   - Test core functionality like job scraping and data export
   - Check that all routes load properly in the web interface
3. Backup the archive (`job_scraper_archive_*.tar.gz`) for future reference.
4. Delete the temporary archive directory (`archived_files/`) after confirming the archive is intact.

## Notes for Deployment

- Always test the application after archiving to ensure all necessary components are present.
- In a production environment, consider removing development and test files completely to reduce attack surface.
- Keep the `.env.example` file but create a proper `.env` file with actual values for the production environment.
- Update the main `README.md` with essential information from the archived documentation.
- Consider setting up CI/CD pipelines for automated testing and deployment in production environments.
