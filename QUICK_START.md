# Job Scraper Quick Start Guide

This guide will help you quickly set up and run the Job Scraper system with the normalized database schema.

## Prerequisites

- Docker and Docker Compose installed
- At least 4GB of RAM available
- At least 20GB of disk space

## Step 1: Clone the Repository (if needed)

```bash
git clone https://github.com/example/job_scraper.git
cd job_scraper
```

## Step 2: Quick Installation

For a complete installation, run:

```bash
./install.sh
```

This will:
- Check prerequisites
- Create necessary secrets
- Set up all services (database, scraper, pgAdmin, Superset)
- Apply database migrations to create the normalized schema
- Start all services

## Step 3: Verify Installation

After installation completes, you can access:

- **Job Scraper API**: http://localhost:8081
- **PgAdmin**: http://localhost:5050
  - Email: admin@example.com
  - Password: admin123secure (or check secrets/pgadmin_password.txt)
- **Superset**: http://localhost:8088
  - Username: admin
  - Password: admin123secure (or check secrets/superset_admin_password.txt)

## Step 4: Connect to the Database

You can connect to the database directly using:

```bash
docker exec -it job_db psql -U jobuser -d jobsdb
```

Or use your favorite PostgreSQL client with these details:
- Host: localhost
- Port: 5432
- Database: jobsdb
- Username: jobuser
- Password: (stored in secrets/db_password.txt)

## Common Commands

```bash
# Start all services
docker-compose up -d

# Stop all services
docker-compose down

# View logs for a service
docker logs job_scraper
docker logs job_db

# Clean up all resources
./cleanup.sh

# Set up just the database (for development)
./setup-db.sh

# Create a database backup
docker exec job_db pg_dump -U jobuser -d jobsdb > backup.sql
```

## Troubleshooting

If you encounter issues:

1. Check the logs: `docker logs job_db`
2. Run cleanup and try again: `./cleanup.sh && ./install.sh`
3. Try database-only setup: `./setup-db.sh`
4. Check if all required directories exist (migrations, job_data, config, etc.)

## Data Schema Overview

The normalized database schema includes:

- `jobs`: Main table storing job postings
- `companies`: Normalized company information
- `job_tags` & `jobs_tags`: Tag data and relationships
- `job_categories` & `jobs_categories`: Category hierarchy
- `locations` & `job_locations`: Location data
- `work_types` & `job_work_types`: Work type information

For more details, see the [Migration README](migrations/README.md). 