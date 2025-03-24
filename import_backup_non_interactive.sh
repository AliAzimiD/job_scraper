#!/bin/bash

# Non-interactive import of PostgreSQL backup to job scraper database
# This script handles importing the jobsdb_backup.dump file into the scraper database

# Set variables for database connection
DB_HOST="db"          # Docker container service name
DB_PORT="5432"
DB_NAME="jobsdb"
DB_USER="jobuser"
DB_PASSWORD="devpassword"

# Set backup file path
BACKUP_FILE="jobsdb_backup.dump"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Check if backup file exists
if [ ! -f "$BACKUP_FILE" ]; then
    echo -e "${RED}Error: Backup file $BACKUP_FILE not found.${NC}"
    exit 1
fi

# Print start message
echo -e "${GREEN}Starting import of $BACKUP_FILE to $DB_NAME database...${NC}"

# Check if Docker is running
if ! docker ps >/dev/null 2>&1; then
    echo -e "${RED}Error: Docker is not running. Please start Docker and try again.${NC}"
    exit 1
fi

# Check if the database container is running
if ! docker ps | grep job_db_dev >/dev/null; then
    echo -e "${RED}Error: Database container (job_db_dev) is not running.${NC}"
    echo -e "${YELLOW}Try running: docker-compose -f docker-compose.dev.yml up -d db${NC}"
    exit 1
fi

# Create temporary directory for modifications
TEMP_DIR=$(mktemp -d)
echo -e "${YELLOW}Using temporary directory: $TEMP_DIR${NC}"

# Extract schema to temporary directory
echo -e "${YELLOW}Extracting schema from backup...${NC}"
pg_restore -f "$TEMP_DIR/schema.sql" --schema-only "$BACKUP_FILE"

# Extract data to temporary directory
echo -e "${YELLOW}Extracting data from backup...${NC}"
pg_restore -f "$TEMP_DIR/data.sql" --data-only "$BACKUP_FILE"

# Warning about dropping data
echo -e "${YELLOW}WARNING: This will drop all existing data in your database.${NC}"
echo -e "${YELLOW}Proceeding with the import...${NC}"

# Copy backup file to the database container
echo -e "${YELLOW}Copying backup file to database container...${NC}"
docker cp "$BACKUP_FILE" job_db_dev:/tmp/

# Connect to the database and perform the import
echo -e "${YELLOW}Importing backup...${NC}"
docker exec job_db_dev bash -c "
    # Set PGPASSWORD for authentication
    export PGPASSWORD='$DB_PASSWORD'
    
    echo 'Dropping existing tables (if any)...'
    psql -U $DB_USER -d $DB_NAME -c 'DROP TABLE IF EXISTS jobs, job_batches, jobs_temp, scraper_stats CASCADE;'
    
    echo 'Importing from backup...'
    pg_restore -U $DB_USER -d $DB_NAME --clean --if-exists --no-owner --no-acl /tmp/$BACKUP_FILE
    
    echo 'Analyzing database...'
    psql -U $DB_USER -d $DB_NAME -c 'ANALYZE;'
    
    echo 'Setting proper sequence values...'
    psql -U $DB_USER -d $DB_NAME -c 'SELECT setval(pg_get_serial_sequence(\"public.scraper_stats\", \"id\"), COALESCE(MAX(id), 0) + 1, false) FROM public.scraper_stats;'
    
    echo 'Cleaning up...'
    rm /tmp/$BACKUP_FILE
"

# Check import result
if [ $? -eq 0 ]; then
    echo -e "${GREEN}Import completed successfully!${NC}"
    echo -e "${GREEN}Counting records in jobs table...${NC}"
    docker exec job_db_dev psql -U $DB_USER -d $DB_NAME -c "SELECT COUNT(*) FROM jobs;"
else
    echo -e "${RED}Import failed.${NC}"
    exit 1
fi

# Clean up temporary files
echo -e "${YELLOW}Cleaning up temporary files...${NC}"
rm -rf "$TEMP_DIR"

echo -e "${GREEN}Import process completed.${NC}" 