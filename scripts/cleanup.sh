#!/bin/bash
# Get script directory
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print a section header
section() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

# Print a success message
success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Print an error message
error() {
    echo -e "${RED}✗ $1${NC}"
}

# Print a warning message
warning() {
    echo -e "${YELLOW}! $1${NC}"
}

# Function to check if Docker is running
check_docker() {
    if ! docker info > /dev/null 2>&1; then
        error "Docker is not running. Please start Docker and try again."
        exit 1
    fi
    success "Docker is running"
}

section "Docker Resource Cleanup"
echo "This script will stop and remove all Docker resources related to the job_scraper project."
echo "This includes containers, volumes, and networks."
echo ""
echo -e "${YELLOW}Warning: This action is irreversible and will delete all data stored in Docker volumes!${NC}"
echo ""

# Check if Docker is running
check_docker

# Ask for confirmation
read -p "Are you sure you want to proceed? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Cleanup aborted."
    exit 0
fi

# Optional backup before cleanup
if [ -d "db" ] || docker ps -a | grep -q "job_db"; then
    read -p "Would you like to create a backup before cleaning up? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        section "Creating Backup"
        if [ ! -d "backups" ]; then
            mkdir -p backups
        fi
        backup_file="backups/jobsdb_backup_$(date +%Y%m%d_%H%M%S).sql"
        echo "Creating database backup to $backup_file..."
        if docker ps | grep -q "job_db"; then
            docker exec job_db pg_dump -U jobuser -d jobsdb > "$backup_file" 2>/dev/null
            if [ $? -eq 0 ] && [ -s "$backup_file" ]; then
                success "Backup created successfully"
            else
                warning "Backup may be incomplete or failed"
                rm -f "$backup_file" 2>/dev/null
            fi
        else
            warning "Database container is not running, cannot create backup"
        fi
    fi
fi

# Stop and remove containers
section "Stopping and Removing Containers"

# First try docker-compose down
echo "Stopping containers with docker-compose..."
if [ -f "docker-compose.yml" ]; then
    docker-compose down -v 2>/dev/null || true
fi

# Then find and remove any remaining containers
echo "Finding and removing any remaining job_ containers..."
container_count=0
for container in $(docker ps -a | grep job_ | awk '{print $1}'); do
    container_name=$(docker inspect --format='{{.Name}}' $container 2>/dev/null || echo $container)
    echo "Stopping and removing container $container_name..."
    docker stop $container 2>/dev/null || true
    docker rm -f $container 2>/dev/null || true
    ((container_count++))
done

if [ $container_count -gt 0 ]; then
    success "Removed $container_count containers"
else
    success "No job_scraper containers found"
fi

# Remove volumes
section "Removing Volumes"
volumes_removed=0
for volume in job_postgres_data job_pgadmin_data job_superset_home; do
    if docker volume ls | grep -q "$volume"; then
        echo "Removing volume $volume..."
        docker volume rm $volume 2>/dev/null || true
        ((volumes_removed++))
    fi
done

if [ $volumes_removed -gt 0 ]; then
    success "Removed $volumes_removed volumes"
else
    success "No job_scraper volumes found"
fi

# Remove networks
section "Removing Networks"
networks_removed=0
for network in $(docker network ls | grep job_scraper | awk '{print $1}'); do
    network_name=$(docker network inspect --format='{{.Name}}' $network 2>/dev/null || echo $network)
    echo "Removing network $network_name..."
    docker network rm $network 2>/dev/null || true
    ((networks_removed++))
done

if [ $networks_removed -gt 0 ]; then
    success "Removed $networks_removed networks"
else
    success "No job_scraper networks found"
fi

# Clean Docker system (optional)
section "Docker System Cleanup"
read -p "Would you like to run a general Docker cleanup (system prune)? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Running docker system prune to remove unused resources..."
    docker system prune -f
    success "Docker system pruned"
else
    success "Skipped general Docker cleanup"
fi

section "Cleanup Complete"
echo "All Docker resources related to job_scraper have been removed."
echo "You can now run ./install.sh to set up a fresh installation."

# Check if backup was created
if [ -n "$backup_file" ] && [ -f "$backup_file" ]; then
    echo ""
    echo "A backup was created at: $backup_file"
    echo "To restore this backup after installation:"
    echo "  cat $backup_file | docker exec -i job_db psql -U jobuser -d jobsdb"
fi 