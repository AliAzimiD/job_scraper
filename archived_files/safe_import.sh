#!/bin/bash

# Safe import script for job scraper database
# This script first backs up the current database and then imports the new backup

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Print start message
echo -e "${GREEN}Starting safe import process...${NC}"
echo -e "${YELLOW}This script will:${NC}"
echo -e "  ${YELLOW}1. Back up your current database${NC}"
echo -e "  ${YELLOW}2. Import the jobsdb_backup.dump file${NC}"
echo -e "${YELLOW}All your current data will be replaced with data from the backup.${NC}"

# Ask for confirmation
read -p "Do you want to continue? (y/n): " confirm
if [[ $confirm != [yY] && $confirm != [yY][eE][sS] ]]; then
    echo -e "${RED}Operation cancelled.${NC}"
    exit 1
fi

# Check if script files exist
if [ ! -f "./backup_current_db.sh" ]; then
    echo -e "${RED}Error: backup_current_db.sh not found in the current directory.${NC}"
    exit 1
fi

if [ ! -f "./import_backup.sh" ]; then
    echo -e "${RED}Error: import_backup.sh not found in the current directory.${NC}"
    exit 1
fi

# Step 1: Backup current database
echo -e "\n${GREEN}=== Step 1: Backing up current database ===${NC}"
./backup_current_db.sh

# Check if backup was successful
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to back up current database. Aborting import.${NC}"
    exit 1
fi

# Step 2: Import new backup
echo -e "\n${GREEN}=== Step 2: Importing new backup ===${NC}"
./import_backup.sh

# Check if import was successful
if [ $? -ne 0 ]; then
    echo -e "${RED}Error: Failed to import new backup.${NC}"
    echo -e "${YELLOW}Your current database has been backed up. You can restore it manually if needed.${NC}"
    exit 1
fi

echo -e "\n${GREEN}Safe import process completed successfully!${NC}"
echo -e "${GREEN}Summary:${NC}"
echo -e "  ${GREEN}- Your previous database has been backed up${NC}"
echo -e "  ${GREEN}- The new database has been imported from jobsdb_backup.dump${NC}"
echo -e "\n${YELLOW}To verify the import, you can run:${NC}"
echo -e "  ${YELLOW}docker exec -it job_db_dev psql -U jobuser -d jobsdb -c \"SELECT COUNT(*) FROM jobs;\"${NC}" 