#!/bin/bash

# Script to properly archive the src directory
# This script handles the case where there might be conflicts with existing directories

# Color codes for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

ARCHIVE_DIR="archived_files"

# Make sure archived_files directory exists
mkdir -p "$ARCHIVE_DIR"

# Check if src directory exists
if [ ! -d "src" ]; then
    echo -e "${YELLOW}Source directory 'src' doesn't exist, nothing to archive${NC}"
    exit 0
fi

# Check if destination already exists
if [ -d "$ARCHIVE_DIR/src" ]; then
    echo -e "${YELLOW}Destination directory '$ARCHIVE_DIR/src' already exists${NC}"
    
    # Create a temporary directory with timestamp
    TEMP_DIR="$ARCHIVE_DIR/src_$(date +"%Y%m%d_%H%M%S")"
    echo -e "${BLUE}Creating temporary directory: $TEMP_DIR${NC}"
    
    # Move contents to temporary directory
    echo -e "${GREEN}Moving 'src' to temporary directory${NC}"
    mv "src" "$TEMP_DIR"
    
    echo -e "${GREEN}Successfully archived src to $TEMP_DIR${NC}"
else
    # Archive directory normally
    echo -e "${GREEN}Archiving 'src' directory${NC}"
    mv "src" "$ARCHIVE_DIR/" && echo -e "${GREEN}Successfully archived src${NC}" || echo -e "${RED}Failed to move src${NC}"
fi

echo -e "${GREEN}Done!${NC}" 