# Job Scraper Utility Scripts

This directory contains utility scripts for managing the Job Scraper application.

## Installation and Setup

- `setup-db.sh` - Sets up only the database (useful for development)
- `setup-minimal.sh` - Minimal setup with just the database and PgAdmin

## Maintenance Scripts

- `cleanup.sh` - Stops and removes all Docker resources related to the job_scraper project
- `run-migrations.sh` - Runs only the database migrations
- `start-db.sh` - Starts only the database container
- `docker_manage.sh` - Docker management utilities for the job scraper

## Usage

Most scripts can be run directly:

```bash
./scripts/cleanup.sh   # Clean up all Docker resources
./scripts/start-db.sh  # Start just the database
```

For other scripts, check the script header for specific instructions. 