#!/bin/bash

# Job Scraper Project Archive Script
# This script archives non-essential files and directories to clean up the project.
# The archived files are moved to an "archived_files" directory and then compressed.

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Timestamp for the archive
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
ARCHIVE_DIR="archived_files"
ARCHIVE_NAME="job_scraper_archive_${TIMESTAMP}.tar.gz"

# Create archive directory if it doesn't exist
mkdir -p "$ARCHIVE_DIR"

echo -e "${BLUE}=== Job Scraper Archive Script ===${NC}"
echo -e "${YELLOW}Creating archive directory: $ARCHIVE_DIR${NC}"

# Function to archive a file if it exists
archive_file() {
    if [ -f "$1" ]; then
        echo -e "${GREEN}Archiving file: $1${NC}"
        # Create parent directory structure if needed
        mkdir -p "$ARCHIVE_DIR/$(dirname "$1")"
        
        # Try to copy first (safer than move if permission issues)
        if cp "$1" "$ARCHIVE_DIR/$(dirname "$1")/"; then
            echo -e "${GREEN}Successfully copied: $1${NC}"
            # Only remove original after successful copy
            rm -f "$1" 2>/dev/null || echo -e "${YELLOW}Could not remove original file (permission issue): $1 - skipping removal${NC}"
        else
            echo -e "${YELLOW}Could not copy $1 (permission issue) - using backup method${NC}"
            # Try with sudo if regular copy fails
            if command -v sudo >/dev/null 2>&1; then
                sudo cp "$1" "$ARCHIVE_DIR/$(dirname "$1")/" && 
                sudo rm -f "$1" && 
                echo -e "${GREEN}Successfully archived using sudo: $1${NC}" || 
                echo -e "${RED}Failed to archive with sudo: $1${NC}"
            else
                echo -e "${RED}Could not archive file (no sudo available): $1${NC}"
            fi
        fi
    else
        echo -e "${YELLOW}File not found, skipping: $1${NC}"
    fi
}

# Function to archive a directory if it exists
archive_dir() {
    if [ -d "$1" ]; then
        echo -e "${GREEN}Archiving directory: $1${NC}"
        
        # Create parent directory structure if needed
        mkdir -p "$ARCHIVE_DIR/$(dirname "$1")"
        
        # Handle case where destination directory already exists
        target_dir="$ARCHIVE_DIR/$(dirname "$1")/$(basename "$1")"
        if [ -d "$target_dir" ]; then
            # Use a timestamped directory name to avoid conflicts
            timestamped_dir="${target_dir}_$(date +"%Y%m%d_%H%M%S")"
            echo -e "${YELLOW}Target directory already exists, using timestamped directory: $(basename "$timestamped_dir")${NC}"
            
            # Try to copy first instead of move (safer with permission issues)
            if cp -r "$1" "$timestamped_dir" 2>/dev/null; then
                echo -e "${GREEN}Successfully copied: $1${NC}"
                # Only remove original after successful copy
                rm -rf "$1" 2>/dev/null || echo -e "${YELLOW}Could not remove original directory (permission issue): $1 - skipping removal${NC}"
            else
                echo -e "${YELLOW}Could not copy $1 (permission issue) - using backup method${NC}"
                # Try with sudo if regular copy fails
                if command -v sudo >/dev/null 2>&1; then
                    sudo cp -r "$1" "$timestamped_dir" && 
                    sudo rm -rf "$1" && 
                    echo -e "${GREEN}Successfully archived using sudo: $1${NC}" || 
                    echo -e "${RED}Failed to archive with sudo: $1${NC}"
                else
                    echo -e "${RED}Could not archive directory (no sudo available): $1${NC}"
                fi
            fi
        else
            # Try to copy first instead of move
            if cp -r "$1" "$ARCHIVE_DIR/$(dirname "$1")/" 2>/dev/null; then
                echo -e "${GREEN}Successfully copied: $1${NC}"
                # Only remove original after successful copy
                rm -rf "$1" 2>/dev/null || echo -e "${YELLOW}Could not remove original directory (permission issue): $1 - skipping removal${NC}"
            else
                echo -e "${YELLOW}Could not copy $1 (permission issue) - using backup method${NC}"
                # Try with sudo if regular copy fails
                if command -v sudo >/dev/null 2>&1; then
                    sudo cp -r "$1" "$ARCHIVE_DIR/$(dirname "$1")/" && 
                    sudo rm -rf "$1" && 
                    echo -e "${GREEN}Successfully archived using sudo: $1${NC}" || 
                    echo -e "${RED}Failed to archive with sudo: $1${NC}"
                else
                    echo -e "${RED}Could not archive directory (no sudo available): $1${NC}"
                fi
            fi
        fi
    else
        echo -e "${YELLOW}Directory not found, skipping: $1${NC}"
    fi
}

# Function to create a backup of essential files in a directory before archiving
backup_essential_files() {
    SRC_DIR="$1"
    PATTERN="$2"
    TARGET_DIR="$ARCHIVE_DIR/essential_backups/$(dirname "$SRC_DIR")"
    
    if [ -d "$SRC_DIR" ]; then
        echo -e "${BLUE}Creating backup of essential files in: $SRC_DIR${NC}"
        mkdir -p "$TARGET_DIR"
        find "$SRC_DIR" -name "$PATTERN" -type f -exec cp --parents {} "$TARGET_DIR" \; 2>/dev/null || 
        echo -e "${YELLOW}Some files could not be backed up due to permissions - continuing${NC}"
    fi
}

# Function to safely remove Python cache directories
remove_pycache() {
    dir="$1"
    echo -e "${GREEN}Removing Python cache directory: $dir${NC}"
    rm -rf "$dir" 2>/dev/null || {
        echo -e "${YELLOW}Could not remove cache directory with regular permissions - trying with sudo${NC}" 
        if command -v sudo >/dev/null 2>&1; then
            sudo rm -rf "$dir" && 
            echo -e "${GREEN}Successfully removed using sudo: $dir${NC}" || 
            echo -e "${RED}Failed to remove with sudo, skipping: $dir${NC}"
        else
            echo -e "${RED}Could not remove cache directory (no sudo available): $dir${NC}"
        fi
    }
}

echo -e "\n${BLUE}=== Archiving Temporary Files ===${NC}"

# Temporary files - not needed for production
TEMP_FILES=(
    "fixed_scraper.py"
    "fixed_base.html"
    "final_web_app.py"
    "upload_features.sh"
    "deploy_vps.sh"
    "setup_vps.sh"
    "fixed_dashboard.html"
    "test_app.py"
    "test_export.py"
    "test_import.py"
    "test_results_20250325_133207.log"
    "Dockerfile.dev"
    "docker-compose.dev.yml"
    "DEVELOPMENT_GUIDE.md"
    "API_DOCUMENTATION.md"
    "MONITORING_SETUP.md"
    "DEPLOYMENT_NOTES.md"
    "fix_scraper.sh"
    "fix_frontend.py"
    "install_dev_tools.sh"
    "run_tests.sh"
    "benchmark_results.json"
    "fix_archive_src.sh"
    "ter"
    "README_IDE_SETUP.md"
    "MONITORING.md"
    "PRODUCTION_SETUP.md"
    "RUNNING_LOCALLY.md"
    "WEB_INTERFACE_GUIDE.md"
)

for file in "${TEMP_FILES[@]}"; do
    archive_file "$file"
done

# Archive old archive files
echo -e "\n${BLUE}=== Archiving Old Archive Files ===${NC}"
OLD_ARCHIVES=(
    "job_scraper_archive_20250325_140913.tar.gz"
)

for file in "${OLD_ARCHIVES[@]}"; do
    archive_file "$file"
done

echo -e "\n${BLUE}=== Archiving Log Files ===${NC}"

# Old log files that can be archived
LOG_FILES=(
    "logs/web_app.log"
    "logs/ConfigManager.log"
    "logs/DataManager.log"
    "logs/DatabaseManager.log"
)

for file in "${LOG_FILES[@]}"; do
    archive_file "$file"
done

echo -e "\n${BLUE}=== Archiving Database Dumps ===${NC}"

# Database dumps - can be archived as they are backups
DB_DUMPS=(
    "jobsdb_backup.dump"
    "jobsdb_current_backup_20250320_005940.dump"
    "database_schema.sql"
)

for file in "${DB_DUMPS[@]}"; do
    archive_file "$file"
done

echo -e "\n${BLUE}=== Archiving Export Files ===${NC}"

# Find and archive job export files - Fixed find command syntax
find "uploads" -type f \( -name "job_export_*.json" -o -name "job_export_*.csv" \) 2>/dev/null | while read -r file; do
    archive_file "$file"
done

echo -e "\n${BLUE}=== Archiving Test Files ===${NC}"

# Backup essential unit tests before archiving all tests
backup_essential_files "tests/unit" "*.py"

# Test directories - integration and e2e tests can be archived
TEST_DIRS=(
    "tests/integration"
    "tests/e2e"
)

for dir in "${TEST_DIRS[@]}"; do
    archive_dir "$dir"
done

echo -e "\n${BLUE}=== Archiving Non-Essential Directories ===${NC}"

# Non-essential directories
NONESSENTIAL_DIRS=(
    "monitoring_docs"
    "superset"
    "grafana"
    "prometheus"
    "docker/monitoring"
    "docs"
    "backups"
    "src"  # Legacy code replaced by app/
    ".vscode"
    ".pytest_cache"
    "job_scraper.egg-info"
    "job_data"
)

for dir in "${NONESSENTIAL_DIRS[@]}"; do
    archive_dir "$dir"
done

echo -e "\n${BLUE}=== Removing Python Cache Directories ===${NC}"
# Use find to locate all __pycache__ directories but handle with our safer function
find . -type d -name "__pycache__" 2>/dev/null | while read -r dir; do
    remove_pycache "$dir"
done

echo -e "\n${BLUE}=== Archiving Complete ===${NC}"

# Compress the archived files
if [ -d "$ARCHIVE_DIR" ] && [ "$(ls -A "$ARCHIVE_DIR" 2>/dev/null)" ]; then
    echo -e "${GREEN}Compressing archived files to $ARCHIVE_NAME${NC}"
    tar -czf "$ARCHIVE_NAME" "$ARCHIVE_DIR" 2>/dev/null || 
    { 
        echo -e "${YELLOW}Could not create archive with regular permissions - trying with sudo${NC}"
        if command -v sudo >/dev/null 2>&1; then
            sudo tar -czf "$ARCHIVE_NAME" "$ARCHIVE_DIR" && 
            echo -e "${GREEN}Archive created with sudo: $ARCHIVE_NAME${NC}" || 
            echo -e "${RED}Failed to create archive with sudo${NC}"
        else
            echo -e "${RED}Could not create archive (no sudo available)${NC}"
        fi
    }
    
    if [ -f "$ARCHIVE_NAME" ]; then
        echo -e "${GREEN}Archive created: $ARCHIVE_NAME${NC}"
        echo -e "${YELLOW}After verifying that the application works correctly, you can delete the $ARCHIVE_DIR directory.${NC}"
    else
        echo -e "${RED}Failed to create archive.${NC}"
    fi
else
    echo -e "${RED}No files were archived or archive directory is empty.${NC}"
fi

echo -e "\n${BLUE}=== Post-Archive Steps ===${NC}"
echo -e "1. Verify that all essential files are still present:"
echo -e "   - Check that app/ directory contains core, web, db, monitoring modules"
echo -e "   - Ensure config/ directory contains configuration files"
echo -e "   - Verify that main.py and requirements.txt are present"
echo -e "2. Test the application to ensure it works correctly:"
echo -e "   - Run 'python main.py' and check for errors"
echo -e "   - Test core functionality through the web interface"
echo -e "3. If everything works correctly, you can safely delete the $ARCHIVE_DIR directory"
echo -e "   or keep the compressed archive for future reference"
echo -e "\n${GREEN}Done!${NC}" 