# Job Scraper with Normalized Database

A comprehensive job scraping and analysis system with a normalized database schema for improved performance and data integrity.

## Overview

The Job Scraper is a system that collects job postings from various sources and stores them in a PostgreSQL database. This implementation features a normalized database schema that provides:

- Improved query performance
- Better data integrity
- Enhanced analytics capabilities
- Reduced data redundancy
- More efficient storage utilization

## System Architecture

The system consists of the following components:

- **Job Scraper Service**: Python-based service that collects job data
- **PostgreSQL Database**: Stores job data in a normalized schema
- **PgAdmin**: Web interface for database administration
- **Superset**: Analytics dashboard for visualizing job data

## Directory Structure

The project is organized into the following directories:

- **`config/`**: Configuration files for the Job Scraper
- **`docker/`**: Alternative Docker Compose configurations
- **`init-db/`**: Database initialization scripts
- **`job_data/`**: Data collected by the Job Scraper
- **`migrations/`**: Database migration scripts
- **`scripts/`**: Utility scripts for installation and maintenance
- **`secrets/`**: Secret files for database and service credentials
- **`src/`**: Source code for the Job Scraper
- **`superset/`**: Superset configuration files
- **`archive/`**: Archived/outdated files

## Database Schema

The database follows a normalized design with these main tables:

- `jobs`: Primary table storing job postings
- `companies`: Stores company information
- `job_tags`: Dictionary of job tags
- `jobs_tags`: Join table linking jobs and tags
- `job_categories`: Dictionary of job categories
- `jobs_categories`: Join table linking jobs and categories
- `locations`: Dictionary of locations
- `job_locations`: Join table linking jobs and locations
- `work_types`: Dictionary of work types
- `job_work_types`: Join table linking jobs and work types

Additional features include:

- Materialized views for analytics
- Table partitioning for improved performance
- GIN indexes for text search
- Row-level security for data protection

## Installation

### Prerequisites

- Docker and Docker Compose
- 4GB+ RAM
- 20GB+ disk space

### Standard Installation

To install the system:

```bash
# Clone the repository (if needed)
git clone https://github.com/example/job_scraper.git
cd job_scraper

# Run the installation script
./install.sh
```

The installation script will:
1. Check prerequisites
2. Set up secrets
3. Clean up existing Docker resources
4. Deploy the database and run migrations
5. Start all services

### Alternative Installation (Database Only)

If you encounter any issues with the standard installation, you can use the simplified database setup:

```bash
# Run the simplified database setup
./scripts/setup-db.sh
```

This will:
1. Set up just the PostgreSQL database
2. Apply all migrations
3. Provide connection details

## Usage

### Accessing Services

After installation, you can access the following services:

- **Job Scraper API**: http://localhost:8081
- **PgAdmin**: http://localhost:5050
  - Email: admin@example.com
  - Password: admin
- **Superset**: http://localhost:8088
  - Username: admin
  - Password: admin

### Database Connection

To connect to the database directly:

```bash
docker exec -it job_db psql -U jobuser -d jobsdb
```

Or use your favorite PostgreSQL client with these details:
- Host: localhost
- Port: 5432
- Database: jobsdb
- Username: jobuser
- Password: (stored in secrets/db_password.txt)

## Analytics

The system includes several materialized views for analytics:

- `mv_job_stats_by_company`: Job statistics grouped by company
- `mv_job_stats_by_tag`: Job statistics grouped by tag
- `mv_job_stats_by_category`: Job statistics grouped by category
- `mv_job_stats_by_location`: Job statistics grouped by location
- `mv_tag_co_occurrence`: Analysis of tags that appear together
- `mv_category_tag_relationship`: Analysis of category-tag relationships
- `mv_job_posting_trends`: Job posting trends over time

## Utility Scripts

The `scripts/` directory contains utility scripts for managing the system:

- **Installation and Setup**:
  - `setup-db.sh`: Sets up only the database (useful for development)
  - `setup-minimal.sh`: Minimal setup with just the database and PgAdmin

- **Maintenance Scripts**:
  - `cleanup.sh`: Stops and removes all Docker resources
  - `run-migrations.sh`: Runs only the database migrations
  - `start-db.sh`: Starts only the database container

## Troubleshooting

### Common Issues

1. **Container Configuration Errors**
   - Run `./scripts/cleanup.sh` to remove all containers and volumes
   - Then run `./scripts/setup-db.sh` to set up just the database
   - Finally, try `./install.sh` again

2. **Database Migration Issues**
   - Check the migration logs: `docker logs job_db`
   - Connect to the database and check the status of tables

3. **Service Connectivity Issues**
   - Ensure ports are not in use by other applications
   - Check Docker network configuration

### Logs

To view logs for any service:

```bash
docker logs job_scraper # For the scraper service
docker logs job_db # For the database service
docker logs job_pgadmin # For PgAdmin
docker logs job_superset # For Superset
```

## Maintenance

### Database Backups

To backup the database:

```bash
docker exec -t job_db pg_dump -U jobuser jobsdb > backups/backup_$(date +%Y%m%d).sql
```

### Updating the System

To update the system:

```bash
git pull # Get the latest code
./install.sh # Run the installation script again
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Contributing

Contributions are welcome! Please see CONTRIBUTING.md for details on how to contribute.