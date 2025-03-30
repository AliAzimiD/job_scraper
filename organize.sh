#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Print a section header
section() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

# Print a success message
success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Print a warning
warning() {
    echo -e "${YELLOW}! $1${NC}"
}

# Print an error
error() {
    echo -e "${RED}✗ $1${NC}"
}

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Check if services are running
check_services() {
    section "Checking Running Services"
    if docker ps | grep -q "job_"; then
        running_services=$(docker ps | grep "job_" | awk '{print $NF}' | tr '\n' ', ' | sed 's/,$//')
        warning "The following services are running: $running_services"
        echo "Organization should be safe with running services, but it's recommended to:"
        echo "1. Create a backup first"
        echo "2. Consider stopping services before major reorganization"
        echo ""
        read -p "Continue with organization? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Organization aborted."
            exit 0
        fi
    else
        success "No job_scraper services are currently running"
    fi
}

# Create a full backup before proceeding
create_backup() {
    section "Creating Backup"
    
    # Create backup directory
    timestamp=$(date +%Y%m%d_%H%M%S)
    backup_dir="${SCRIPT_DIR}/pre_organization_backup_${timestamp}"
    mkdir -p "${backup_dir}"
    
    # Back up all script files
    echo "Backing up script files..."
    find "${SCRIPT_DIR}" -maxdepth 1 -name "*.sh" -exec cp {} "${backup_dir}/" \;
    
    # Back up docker-compose files
    echo "Backing up docker-compose files..."
    find "${SCRIPT_DIR}" -maxdepth 1 -name "docker-compose*.yml" -exec cp {} "${backup_dir}/" \;
    
    # Back up key configuration files
    echo "Backing up configuration files..."
    if [ -d "${SCRIPT_DIR}/config" ]; then
        mkdir -p "${backup_dir}/config"
        cp -r "${SCRIPT_DIR}/config"/* "${backup_dir}/config/"
    fi
    
    # Backup database if running
    if docker ps | grep -q "job_db"; then
        echo "Creating database backup..."
        mkdir -p "${backup_dir}/db_backup"
        db_backup_file="${backup_dir}/db_backup/jobsdb_backup_${timestamp}.sql"
        docker exec job_db pg_dump -U jobuser -d jobsdb > "${db_backup_file}" 2>/dev/null || warning "Database backup failed"
        if [ -s "${db_backup_file}" ]; then
            success "Database backup created at ${db_backup_file}"
        else
            warning "Database backup may be empty or incomplete"
        fi
    fi
    
    success "Backup created at ${backup_dir}"
    echo "To restore from this backup, copy files back to their original locations"
}

# Check for hardcoded paths in scripts
check_hardcoded_paths() {
    section "Checking for Hardcoded Paths"
    
    hardcoded_path_count=0
    for script in $(find "${SCRIPT_DIR}" -maxdepth 1 -name "*.sh" | grep -v "organize.sh"); do
        paths_found=$(grep -l "\/root\/karchi\/job_scraper\/" "$script" || true)
        if [ -n "$paths_found" ]; then
            warning "Hardcoded paths found in $script"
            ((hardcoded_path_count++))
        fi
    done
    
    if [ $hardcoded_path_count -gt 0 ]; then
        warning "Found $hardcoded_path_count scripts with hardcoded paths"
        echo "These paths might break after reorganization"
        echo "The script will create fixes to use relative paths instead"
    else
        success "No hardcoded absolute paths found in scripts"
    fi
}

# Fix hardcoded paths in scripts
fix_hardcoded_paths() {
    for script in $(find "${SCRIPT_DIR}/scripts" -name "*.sh"); do
        # Create backup of the script
        cp "$script" "${script}.bak"
        
        # Replace absolute paths with relative ones using script directory detection
        sed -i 's|/root/karchi/job_scraper/|$(dirname "$(readlink -f "$0")")/../|g' "$script"
        
        # Add script directory detection if not present
        if ! grep -q 'SCRIPT_DIR=' "$script"; then
            sed -i '1a\
# Get script directory\
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"\
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"' "$script"
        fi
        
        success "Fixed paths in $script"
    done
}

# Validate docker-compose files
validate_dockercompose() {
    section "Validating Docker Compose Files"
    
    if [ -f "${SCRIPT_DIR}/docker-compose.yml" ]; then
        echo "Checking main docker-compose.yml file..."
        if docker-compose -f "${SCRIPT_DIR}/docker-compose.yml" config > /dev/null 2>&1; then
            success "docker-compose.yml is valid"
        else
            warning "docker-compose.yml may have issues"
        fi
    fi
    
    # Check alternative docker-compose files
    for compose_file in $(find "${SCRIPT_DIR}" -name "docker-compose*.yml" ! -path "*/\.*" ! -path "${SCRIPT_DIR}/docker-compose.yml"); do
        echo "Checking $compose_file..."
        if docker-compose -f "$compose_file" config > /dev/null 2>&1; then
            success "$compose_file is valid"
        else
            warning "$compose_file may have issues"
        fi
    done
}

section "Job Scraper Directory Organization"
echo "This script will organize the files in the job_scraper directory."
echo "It will move files to their appropriate directories without affecting running services."
echo ""
echo "The organization plan:"
echo "1. Create a backup of critical files"
echo "2. Check for potential issues with hardcoded paths" 
echo "3. Move installation scripts to archive or scripts directory"
echo "4. Move Docker Compose files to docker directory"
echo "5. Move utility scripts to scripts directory"
echo "6. Create symlinks to maintain compatibility"
echo "7. Fix any hardcoded paths in moved scripts"
echo ""
warning "Make sure to backup any important files before proceeding."
echo ""

# Ask for confirmation
read -p "Do you want to proceed with the organization? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Organization aborted."
    exit 0
fi

# Run pre-checks
check_services
create_backup
check_hardcoded_paths
validate_dockercompose

section "Moving Files"

# Move installation scripts
echo "Moving installation scripts..."
[ -f "${SCRIPT_DIR}/fresh-install.sh" ] && mv "${SCRIPT_DIR}/fresh-install.sh" "${SCRIPT_DIR}/archive/" && success "Moved fresh-install.sh to archive/"
[ -f "${SCRIPT_DIR}/complete-setup.sh" ] && mv "${SCRIPT_DIR}/complete-setup.sh" "${SCRIPT_DIR}/archive/" && success "Moved complete-setup.sh to archive/"
[ -f "${SCRIPT_DIR}/install-fixed.sh" ] && mv "${SCRIPT_DIR}/install-fixed.sh" "${SCRIPT_DIR}/archive/" && success "Moved install-fixed.sh to archive/"
[ -f "${SCRIPT_DIR}/archive/install.sh.bak" ] || ([ -f "${SCRIPT_DIR}/install.sh" ] && cp "${SCRIPT_DIR}/install.sh" "${SCRIPT_DIR}/archive/install.sh.bak" && success "Backed up install.sh to archive/")

# Move Docker Compose files (make copies to ensure running services aren't affected)
echo "Moving Docker Compose files..."
[ -f "${SCRIPT_DIR}/docker-compose.dev.yml" ] && mv "${SCRIPT_DIR}/docker-compose.dev.yml" "${SCRIPT_DIR}/docker/" && success "Moved docker-compose.dev.yml to docker/"
[ -f "${SCRIPT_DIR}/docker-compose.minimal.yml" ] && mv "${SCRIPT_DIR}/docker-compose.minimal.yml" "${SCRIPT_DIR}/docker/" && success "Moved docker-compose.minimal.yml to docker/"
[ -f "${SCRIPT_DIR}/migrations/docker-compose.updated.yml" ] && cp "${SCRIPT_DIR}/migrations/docker-compose.updated.yml" "${SCRIPT_DIR}/docker/" && success "Copied docker-compose.updated.yml to docker/"
[ -f "${SCRIPT_DIR}/migrations/simplified-compose.yml" ] && cp "${SCRIPT_DIR}/migrations/simplified-compose.yml" "${SCRIPT_DIR}/docker/" && success "Copied simplified-compose.yml to docker/"

# Move utility scripts
echo "Moving utility scripts..."
[ -f "${SCRIPT_DIR}/cleanup.sh" ] && mv "${SCRIPT_DIR}/cleanup.sh" "${SCRIPT_DIR}/scripts/" && ln -sf scripts/cleanup.sh "${SCRIPT_DIR}/" && success "Moved cleanup.sh to scripts/ and created symlink"
[ -f "${SCRIPT_DIR}/run-migrations.sh" ] && mv "${SCRIPT_DIR}/run-migrations.sh" "${SCRIPT_DIR}/scripts/" && ln -sf scripts/run-migrations.sh "${SCRIPT_DIR}/" && success "Moved run-migrations.sh to scripts/ and created symlink"
[ -f "${SCRIPT_DIR}/start-db.sh" ] && mv "${SCRIPT_DIR}/start-db.sh" "${SCRIPT_DIR}/scripts/" && ln -sf scripts/start-db.sh "${SCRIPT_DIR}/" && success "Moved start-db.sh to scripts/ and created symlink"
[ -f "${SCRIPT_DIR}/setup-db.sh" ] && mv "${SCRIPT_DIR}/setup-db.sh" "${SCRIPT_DIR}/scripts/" && ln -sf scripts/setup-db.sh "${SCRIPT_DIR}/" && success "Moved setup-db.sh to scripts/ and created symlink"
[ -f "${SCRIPT_DIR}/setup-minimal.sh" ] && mv "${SCRIPT_DIR}/setup-minimal.sh" "${SCRIPT_DIR}/scripts/" && ln -sf scripts/setup-minimal.sh "${SCRIPT_DIR}/" && success "Moved setup-minimal.sh to scripts/ and created symlink"
[ -f "${SCRIPT_DIR}/docker_manage.sh" ] && mv "${SCRIPT_DIR}/docker_manage.sh" "${SCRIPT_DIR}/scripts/" && success "Moved docker_manage.sh to scripts/"

# Fix hardcoded paths in moved scripts
fix_hardcoded_paths

section "Creating Documentation"

# Create a document explaining how to revert if needed
cat > "${SCRIPT_DIR}/REVERT_ORGANIZATION.md" << 'EOL'
# How to Revert Directory Organization

If you need to revert the directory organization for any reason, follow these steps:

## Immediate Reversion (Using Backup)

1. **Restore from Backup**:
   ```bash
   # Replace with your actual backup directory
   BACKUP_DIR="./pre_organization_backup_YYYYMMDD_HHMMSS"
   
   # Restore script files
   cp ${BACKUP_DIR}/*.sh .
   
   # Restore docker-compose files
   cp ${BACKUP_DIR}/docker-compose*.yml .
   ```

2. **Remove Symlinks**:
   ```bash
   rm cleanup.sh run-migrations.sh start-db.sh setup-db.sh setup-minimal.sh
   ```

## Manual Reversion

If you don't have a backup:

1. **Move Scripts Back**:
   ```bash
   mv scripts/*.sh .
   ```

2. **Move Docker Compose Files Back**:
   ```bash
   mv docker/*.yml .
   ```

3. **Move Archived Files Back**:
   ```bash
   mv archive/*.sh .
   ```

## Check Services After Reversion

After reverting, check if services are running correctly:

```bash
docker-compose ps
```

If services are not running properly, you may need to restart them:

```bash
docker-compose down
docker-compose up -d
```
EOL

success "Created reversion documentation"

section "Organization Complete"
echo "The job_scraper directory has been organized."
echo "Symlinks have been created for commonly used scripts, so you can still run them from the root directory."
echo ""
echo "New directory structure:"
echo "- archive/ - Contains old/archived files"
echo "- docker/ - Contains Docker Compose configuration files"
echo "- scripts/ - Contains utility scripts"
echo ""
echo "If you encounter any issues, see REVERT_ORGANIZATION.md for instructions on how to revert changes."
echo ""
echo "You can safely remove the organize.sh script after reviewing the changes." 