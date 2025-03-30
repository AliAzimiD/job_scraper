# Database Migration Guide

This directory contains SQL scripts to migrate the job_scraper database to a normalized and optimized schema.

## Migration Overview

The migration process includes:

1. Creating normalized tables for tags, categories, companies, locations, and work types
2. Migrating data from the original table to the new tables
3. Creating materialized views for analytics
4. Setting up table partitioning for the jobs table
5. Creating database functions and views to abstract the changes

## Migration Files

The migration files are executed in order:

- `01_create_normalized_schema.sql`: Creates new normalized tables and relationships
- `02_migrate_data.sql`: Migrates data from original tables to the new tables
- `03_create_materialized_views.sql`: Creates materialized views for analytics
- `04_setup_partitioning.sql`: Sets up table partitioning for the jobs table
- `05_modify_database_access.sql`: Creates functions and views to abstract the database access
- `06_update_db_manager.py`: Python code to update the database manager

## How to Apply Migrations

### Method 1: Using the Migration Runner

```bash
# Apply migrations using the runner script
python -m src.run_migrations

# Optionally specify target version
python -m src.run_migrations 2
```

### Method 2: Using Docker

The migrations can be applied using the migrator service in docker-compose:

```bash
# Apply migrations on a running system
docker-compose --profile migrations up migrator

# After completion, Ctrl+C to stop the service
```

### Method 3: Manual Application

For manual application, you can run the SQL scripts directly:

```bash
# Connect to the database
docker-compose exec db psql -U jobuser -d jobsdb

# Inside psql, run each migration script
\i /docker-entrypoint-migrations/01_create_normalized_schema.sql
\i /docker-entrypoint-migrations/02_migrate_data.sql
\i /docker-entrypoint-migrations/03_create_materialized_views.sql
\i /docker-entrypoint-migrations/04_setup_partitioning.sql
\i /docker-entrypoint-migrations/05_modify_database_access.sql
```

## New Tables Overview

The migration creates these tables:

- `companies`: Normalized company information
- `job_tags`: Master list of job tags
- `jobs_tags`: Join table linking jobs to tags
- `job_categories`: Master list of job categories with parent-child relationships
- `jobs_categories`: Join table linking jobs to categories
- `locations`: Master list of locations (cities, provinces, districts)
- `job_locations`: Join table linking jobs to locations
- `work_types`: Master list of work types
- `job_work_types`: Join table linking jobs to work types
- `jobs_partitioned`: Partitioned table for jobs by month

## New Views & Functions

The migration also creates:

- `jobs_unified`: View with joined data from all tables
- `insert_job()`: Function to insert jobs with normalized data
- `update_job_batch()`: Function to update job batch status
- `get_jobs()`: Function to fetch jobs with various filters
- Several materialized views for analytics purposes

## Data Verification

After migration, you can verify the data integrity:

```sql
-- Count jobs in original and new tables
SELECT COUNT(*) FROM jobs;
SELECT COUNT(*) FROM jobs_partitioned;

-- Check tag migration
SELECT COUNT(*) FROM job_tags;
SELECT COUNT(*) FROM jobs_tags;

-- Check category migration
SELECT COUNT(*) FROM job_categories;
SELECT COUNT(*) FROM jobs_categories;
```

## Rollback

If needed, you can revert to the original tables:

```sql
-- Create a view that points back to the original table
CREATE OR REPLACE VIEW jobs_view AS SELECT * FROM jobs;
```

## Database Schema Version

The migration process tracks schema version in the `schema_version` table:

- Version 1: Original schema
- Version 2: Normalized schema with tags, categories, companies, etc.

To check the current version:

```sql
SELECT MAX(version) FROM schema_version;
``` 