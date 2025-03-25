#!/bin/bash

# Job Scraper Archive Process Script
# This script runs the archive process and performs validation checks

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Job Scraper Archive Process ===${NC}"
echo -e "${YELLOW}Starting archive process with validation${NC}"

# Function to check if essential files/directories exist
check_essential_files() {
    echo -e "\n${BLUE}=== Checking Essential Files ===${NC}"
    
    ESSENTIAL_FILES=(
        "main.py"
        "requirements.txt"
        ".env.example"
        "README.md"
        "docker-compose.yml"
        "Dockerfile"
    )
    
    ESSENTIAL_DIRS=(
        "app"
        "config"
    )
    
    ALL_PRESENT=true
    
    # Check essential files
    for file in "${ESSENTIAL_FILES[@]}"; do
        if [ -f "$file" ]; then
            echo -e "${GREEN}✓ Essential file present: $file${NC}"
        else
            echo -e "${RED}✗ Missing essential file: $file${NC}"
            ALL_PRESENT=false
        fi
    done
    
    # Check essential directories
    for dir in "${ESSENTIAL_DIRS[@]}"; do
        if [ -d "$dir" ]; then
            echo -e "${GREEN}✓ Essential directory present: $dir${NC}"
        else
            echo -e "${RED}✗ Missing essential directory: $dir${NC}"
            ALL_PRESENT=false
        fi
    done
    
    # Check app subdirectories
    APP_SUBDIRS=(
        "app/core"
        "app/web"
        "app/db"
        "app/monitoring"
        "app/utils"
        "app/templates"
    )
    
    for dir in "${APP_SUBDIRS[@]}"; do
        if [ -d "$dir" ]; then
            echo -e "${GREEN}✓ App component present: $dir${NC}"
        else
            echo -e "${YELLOW}! App component may be missing: $dir${NC}"
        fi
    done
    
    if [ "$ALL_PRESENT" = true ]; then
        echo -e "${GREEN}All essential files and directories are present.${NC}"
        return 0
    else
        echo -e "${RED}Some essential files or directories are missing.${NC}"
        return 1
    fi
}

# Function to create a backup of the current state
create_backup() {
    echo -e "\n${BLUE}=== Creating Backup ===${NC}"
    BACKUP_NAME="pre_archive_backup_$(date +"%Y%m%d_%H%M%S").tar.gz"
    
    echo -e "${YELLOW}Creating backup: $BACKUP_NAME${NC}"
    # Exclude large directories and already archived files
    tar --exclude="archived_files" --exclude="*.tar.gz" --exclude="venv" --exclude="__pycache__" -czf "$BACKUP_NAME" . 2>/dev/null
    
    # Check if backup failed due to permissions, try with sudo
    if [ $? -ne 0 ]; then
        echo -e "${YELLOW}Backup failed with regular permissions - trying with sudo${NC}"
        if command -v sudo >/dev/null 2>&1; then
            sudo tar --exclude="archived_files" --exclude="*.tar.gz" --exclude="venv" --exclude="__pycache__" -czf "$BACKUP_NAME" .
            
            if [ $? -eq 0 ]; then
                # Make sure the user can access the backup file
                sudo chmod 644 "$BACKUP_NAME" 2>/dev/null
                echo -e "${GREEN}Backup created successfully with sudo.${NC}"
                return 0
            else
                echo -e "${RED}Failed to create backup with sudo.${NC}"
                return 1
            fi
        else
            echo -e "${RED}Failed to create backup (sudo not available).${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}Backup created successfully.${NC}"
        return 0
    fi
}

# Function to verify application functionality
verify_app() {
    echo -e "\n${BLUE}=== Verifying Application ===${NC}"
    echo -e "${YELLOW}Running basic application check...${NC}"
    
    # Try different possible Python commands
    PYTHON_CMD=""
    for cmd in python python3 python3.8 python3.9 python3.10 python3.11; do
        if command -v $cmd >/dev/null 2>&1; then
            PYTHON_CMD=$cmd
            echo -e "${GREEN}Found Python command: $PYTHON_CMD${NC}"
            break
        fi
    done
    
    # If no Python command was found
    if [ -z "$PYTHON_CMD" ]; then
        echo -e "${RED}No Python command found. Please ensure Python is installed and in your PATH.${NC}"
        echo -e "${YELLOW}Possible solutions:${NC}"
        echo -e "1. Install Python if not already installed"
        echo -e "2. Activate your virtual environment: source venv/bin/activate"
        echo -e "3. Add Python to your PATH environment variable"
        echo -e "4. Manually verify the application with your specific Python setup"
        
        # Ask if the user wants to skip this check
        echo -e "${YELLOW}Do you want to skip the Python verification and continue? (y/n)${NC}"
        read -r skip_python_check
        if [[ "$skip_python_check" == "y" || "$skip_python_check" == "Y" ]]; then
            echo -e "${YELLOW}Skipping Python verification.${NC}"
            return 0
        else
            return 1
        fi
    fi
    
    # Run a simple test to see if the application can be imported without errors
    PYTHON_CHECK=$($PYTHON_CMD -c "import sys; sys.path.append('.'); import main; print('Application import successful')" 2>&1)
    
    if [[ "$PYTHON_CHECK" == *"Application import successful"* ]]; then
        echo -e "${GREEN}Application import check passed.${NC}"
        return 0
    else
        echo -e "${RED}Application import check failed:${NC}"
        echo -e "${RED}$PYTHON_CHECK${NC}"
        
        # Provide guidance on potential fixes
        echo -e "${YELLOW}Potential issues:${NC}"
        echo -e "1. Python path issues - check if essential modules are still accessible"
        echo -e "2. Missing dependencies - verify requirements.txt and installed packages"
        echo -e "   Try: $PYTHON_CMD -m pip install -r requirements.txt"
        echo -e "3. Permission problems - check file access permissions"
        echo -e "4. Virtual environment may be needed - try activating it first:"
        echo -e "   source venv/bin/activate  # or equivalent for your environment"
        
        # Ask if the user wants to skip this check
        echo -e "${YELLOW}Do you want to skip the Python verification and continue anyway? (y/n)${NC}"
        read -r skip_verification
        if [[ "$skip_verification" == "y" || "$skip_verification" == "Y" ]]; then
            echo -e "${YELLOW}Skipping verification. Please test the application manually.${NC}"
            return 0
        else
            return 1
        fi
    fi
}

# Function to handle script execution with proper error trapping
run_script() {
    script_name="$1"
    echo -e "\n${BLUE}=== Running Script: $script_name ===${NC}"
    
    if [ -f "$script_name" ]; then
        # Make script executable if it isn't already
        chmod +x "$script_name" 2>/dev/null || {
            echo -e "${YELLOW}Could not make script executable with regular permissions - trying with sudo${NC}"
            if command -v sudo >/dev/null 2>&1; then
                sudo chmod +x "$script_name"
            else
                echo -e "${RED}Could not make script executable - no sudo available${NC}"
                return 1
            fi
        }
        
        # Run the script and capture output and return code
        echo -e "${YELLOW}Executing $script_name...${NC}"
        output=$(./"$script_name" 2>&1)
        ret_val=$?
        
        # Print output
        echo "$output"
        
        # Check return code
        if [ $ret_val -ne 0 ]; then
            echo -e "${RED}Script execution failed with exit code $ret_val${NC}"
            return 1
        else
            echo -e "${GREEN}Script executed successfully.${NC}"
            return 0
        fi
    else
        echo -e "${RED}Script not found: $script_name${NC}"
        return 1
    fi
}

# Main process
echo -e "\n${BLUE}=== Starting Archive Process ===${NC}"

# Check essential files before archiving
check_essential_files

# Create backup before archiving
if create_backup; then
    echo -e "${GREEN}Backup created. Proceeding with archive process.${NC}"
else
    echo -e "${YELLOW}Backup creation failed. Do you want to continue anyway? (y/n)${NC}"
    read -r continue_without_backup
    
    if [[ "$continue_without_backup" != "y" && "$continue_without_backup" != "Y" ]]; then
        echo -e "${RED}Aborting archive process as requested.${NC}"
        exit 1
    else
        echo -e "${YELLOW}Continuing archive process without backup - PROCEED WITH CAUTION${NC}"
    fi
fi

# Run the archive script
if run_script "archive_unused_files.sh"; then
    echo -e "${GREEN}Archive script completed successfully.${NC}"
else
    echo -e "${RED}Archive script failed. Check for errors.${NC}"
    echo -e "${YELLOW}Do you want to continue with validation anyway? (y/n)${NC}"
    read -r continue_with_validation
    
    if [[ "$continue_with_validation" != "y" && "$continue_with_validation" != "Y" ]]; then
        echo -e "${RED}Aborting archive process as requested.${NC}"
        exit 1
    else
        echo -e "${YELLOW}Continuing with validation despite archive script failure.${NC}"
    fi
fi

# Check essential files after archiving
echo -e "\n${BLUE}=== Post-Archive Validation ===${NC}"
if check_essential_files; then
    echo -e "${GREEN}All essential files are still present after archiving.${NC}"
else
    echo -e "${RED}Some essential files may have been accidentally archived.${NC}"
    if [ -f "$BACKUP_NAME" ]; then
        echo -e "${YELLOW}Consider restoring from backup: $BACKUP_NAME${NC}"
        echo -e "${YELLOW}To restore: tar -xzf $BACKUP_NAME${NC}"
    fi
    echo -e "${YELLOW}Do you want to continue with application verification? (y/n)${NC}"
    read -r continue_with_app_check
    
    if [[ "$continue_with_app_check" != "y" && "$continue_with_app_check" != "Y" ]]; then
        echo -e "${RED}Aborting process as requested.${NC}"
        exit 1
    fi
fi

# Verify application functionality
if verify_app; then
    echo -e "${GREEN}Application check passed after archiving.${NC}"
else
    echo -e "${RED}Application check failed after archiving.${NC}"
    if [ -f "$BACKUP_NAME" ]; then
        echo -e "${YELLOW}Consider restoring from backup: $BACKUP_NAME${NC}"
        echo -e "${YELLOW}To restore: tar -xzf $BACKUP_NAME${NC}"
    fi
    exit 1
fi

echo -e "\n${GREEN}Archive process completed successfully.${NC}"
echo -e "${YELLOW}Archive created and application verified.${NC}"
echo -e "${BLUE}After manual verification, you can delete the archived_files directory.${NC}"
echo -e "${BLUE}Keep the compressed archive file for future reference.${NC}"

# Final reminders
echo -e "\n${BLUE}=== Final Reminders ===${NC}"
echo -e "1. Run the application to verify functionality: python main.py"
echo -e "2. Test key features like job scraping, web interface, and data export"
echo -e "3. If you encounter any issues, restore from backup: tar -xzf $BACKUP_NAME"
echo -e "4. Once verified, you can safely remove the archived_files directory"
echo -e "\n${GREEN}Done!${NC}" 