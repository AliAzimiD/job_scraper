#!/bin/bash

# Backup current job scraper database
# This script creates a backup of the current database state before importing a new backup

# Set variables for database connection
DB_HOST="db"          # Docker container service name
DB_PORT="5432"
DB_NAME="jobsdb"
DB_USER="jobuser"
DB_PASSWORD="devpassword"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Create timestamp for the backup filename
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="jobsdb_current_backup_${TIMESTAMP}.dump"

# Print start message
echo -e "${GREEN}Starting backup of current $DB_NAME database...${NC}"

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

# Perform the backup
echo -e "${YELLOW}Creating backup...${NC}"
docker exec -it job_db_dev bash -c "
    # Set PGPASSWORD for authentication
    export PGPASSWORD='$DB_PASSWORD'
    
    # Create backup using pg_dump
    pg_dump -U $DB_USER -d $DB_NAME -F c -f /tmp/$BACKUP_FILE
"

# Check if backup was successful
if [ $? -eq 0 ]; then
    # Copy the backup from the container to the host
    echo -e "${YELLOW}Copying backup file from container to host...${NC}"
    docker cp job_db_dev:/tmp/$BACKUP_FILE .
    
    # Clean up the backup file from the container
    docker exec -it job_db_dev rm /tmp/$BACKUP_FILE
    
    # Check if the backup file exists on the host
    if [ -f "$BACKUP_FILE" ]; then
        BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        echo -e "${GREEN}Backup completed successfully!${NC}"
        echo -e "${GREEN}Backup saved as: $BACKUP_FILE (Size: $BACKUP_SIZE)${NC}"
    else
        echo -e "${RED}Error: Failed to copy backup file from container.${NC}"
        exit 1
    fi
else
    echo -e "${RED}Error: Backup failed.${NC}"
    exit 1
fi

echo -e "${GREEN}Backup process completed.${NC}" 