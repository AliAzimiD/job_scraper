# Database Restructuring Implementation Plan

This document outlines the complete implementation plan for restructuring the job_scraper database to a more normalized and optimized schema.

## Files Created

1. **Migration SQL Scripts**:
   - `01_create_normalized_schema.sql` - Creates new normalized tables and relationships
   - `02_migrate_data.sql` - Migrates data from the original tables to the new tables
   - `03_create_materialized_views.sql` - Creates materialized views for analytics
   - `04_setup_partitioning.sql` - Sets up table partitioning for the jobs table
   - `05_modify_database_access.sql` - Creates database functions and views for abstraction

2. **Python Support Files**:
   - `src/run_migrations.py` - Script to run database migrations automatically
   - `migrations/06_update_db_manager.py` - Updates to the database manager class

3. **Docker and Initialization Files**:
   - `migrations/docker-compose.updated.yml` - Updated docker-compose file with migration support
   - `init-db/02-schema-update.sh` - Script to check and apply schema upgrades during initialization
   - `install.sh` - Main installation script that deploys the updated schema

4. **Documentation**:
   - `migrations/README.md` - Documentation for the migration process
   - `migrations/IMPLEMENTATION_PLAN.md` (this file) - Overview of the implementation plan

## Schema Changes

The implementation creates several normalized tables and relationships:

1. **Companies Table**:
   - Extracts company information from the jobs table
   - Adds proper relationships to jobs

2. **Tags Tables**:
   - Extracts tags from the JSONB array in the jobs table
   - Creates a normalized table for tags and a join table for the relationship

3. **Categories Tables**:
   - Normalizes job categories with parent-child relationships
   - Creates a join table to link jobs to categories

4. **Locations Tables**:
   - Extracts location information from the JSONB array
   - Creates a normalized structure for storing location data

5. **Work Types Tables**:
   - Extracts work type information
   - Creates a normalized structure for work types

6. **Jobs Partitioning**:
   - Partitions the jobs table by month
   - Creates a view for seamless access
   - Sets up triggers to handle CRUD operations
   - Adds a function to automatically create future partitions

7. **Analytics Support**:
   - Creates materialized views for common analytics queries
   - Adds a refresh function to update all views at once

## Integration with Existing Code

The implementation includes:

1. **Updated DB Manager**:
   - Adds schema versioning support
   - Updates methods to work with the new normalized schema
   - Maintains backward compatibility where possible

2. **Database Abstractions**:
   - Creates functions and views that abstract the schema changes
   - Allows existing code to continue working with minimal changes

3. **Migration Support**:
   - Adds a dedicated module for running migrations
   - Supports both automatic and manual migration

## Installation Process

The installation process consists of:

1. **Preparing the Environment**:
   - Setting up necessary directories
   - Ensuring prerequisites are installed

2. **Initializing the Database**:
   - Creating the base schema
   - Applying the migration scripts

3. **Configuring Services**:
   - Updating the docker-compose configuration
   - Starting all required services

4. **Verifying the Installation**:
   - Checking that all tables were created correctly
   - Validating that data was migrated properly

## Verification Steps

After installation, the following verification steps are recommended:

1. **Count Comparison**:
   - Compare the count of records in the original and new tables
   - Ensure all data was properly migrated

2. **Functionality Testing**:
   - Test that the job scraper continues to work
   - Verify that all services (PgAdmin, Superset) can access the data

3. **Performance Testing**:
   - Monitor query performance before and after migration
   - Check that analytics queries use the materialized views

## Rollback Plan

In case of issues, the following rollback steps are available:

1. **View Redirection**:
   - Update the jobs_view to point back to the original table
   - This allows services to continue functioning without schema changes

2. **Database Restore**:
   - If necessary, restore from backup
   - The install script doesn't drop original tables, so data is preserved 