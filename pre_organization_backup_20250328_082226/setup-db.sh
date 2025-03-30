#!/bin/bash
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
    exit 1
}

# Print a warning message
warning() {
    echo -e "${YELLOW}! $1${NC}"
}

# Function to check if Docker is running
check_docker() {
    section "Checking Docker Status"
    if ! docker info > /dev/null 2>&1; then
        error "Docker is not running. Please start Docker and try again."
    fi
    success "Docker is running"
}

section "Job Scraper Database Setup"
echo "This script sets up the PostgreSQL database with normalized schema"

# Check Docker status
check_docker

# Check for existing containers and suggest cleanup if needed
if docker ps -a | grep -q "job_"; then
    warning "Existing containers detected! It's recommended to run ./cleanup.sh first."
    read -p "Would you like to run cleanup first? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Running cleanup..."
        ./cleanup.sh
        success "Cleanup completed"
    fi
fi

# Create password file if it doesn't exist
section "Setting Up Secrets"
if [ ! -d "secrets" ]; then
    mkdir -p secrets
    success "Created secrets directory"
fi

# Check and create necessary password files
files_created=0
if [ ! -f "secrets/db_password.txt" ]; then
    DB_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
    echo "$DB_PASSWORD" > secrets/db_password.txt
    chmod 600 secrets/db_password.txt
    ((files_created++))
fi

if [ ! -f "secrets/pgadmin_email.txt" ]; then
    echo "admin@example.com" > secrets/pgadmin_email.txt
    chmod 600 secrets/pgadmin_email.txt
    ((files_created++))
fi

if [ ! -f "secrets/pgadmin_password.txt" ]; then
    echo "admin123secure" > secrets/pgadmin_password.txt
    chmod 600 secrets/pgadmin_password.txt
    ((files_created++))
fi

if [ ! -f "secrets/superset_secret_key.txt" ]; then
    SUPERSET_KEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
    echo "$SUPERSET_KEY" > secrets/superset_secret_key.txt
    chmod 600 secrets/superset_secret_key.txt
    ((files_created++))
fi

if [ ! -f "secrets/superset_admin_password.txt" ]; then
    echo "admin123secure" > secrets/superset_admin_password.txt
    chmod 600 secrets/superset_admin_password.txt
    ((files_created++))
fi

if [ $files_created -gt 0 ]; then
    success "Created $files_created new secret files"
else
    success "All secret files already exist"
fi

# Create migrations directory if it doesn't exist
if [ ! -d "migrations" ]; then
    mkdir -p migrations
    warning "Created empty migrations directory - you'll need to add migration files"
fi

# Start the database
section "Starting Database"
echo "Starting PostgreSQL database..."

# Check if old container exists and needs to be removed
if docker ps -a | grep -q "job_db"; then
    warning "Existing database container found. Removing it..."
    docker rm -f job_db > /dev/null 2>&1 || true
fi

# Start the database container with proper volume mounts
docker run -d \
    --name job_db \
    --network=bridge \
    -e POSTGRES_USER=jobuser \
    -e POSTGRES_DB=jobsdb \
    -e POSTGRES_PASSWORD="$(cat secrets/db_password.txt)" \
    -e TZ=Asia/Tehran \
    -v "$(pwd)/migrations":/docker-entrypoint-migrations \
    -v "$(pwd)/init-db":/docker-entrypoint-initdb.d \
    -v job_postgres_data:/var/lib/postgresql/data \
    -p 5432:5432 \
    postgres:15-alpine

success "Database container started"

# Wait for database to be ready
echo -n "Waiting for database to be ready"
timeout=30
for i in $(seq 1 $timeout); do
    if docker exec job_db pg_isready -U jobuser -d jobsdb > /dev/null 2>&1; then
        echo ""
        success "Database is ready"
        break
    fi
    echo -n "."
    sleep 2
    if [ $i -eq $timeout ]; then
        echo ""
        error "Database did not become ready in time. Please check the logs with 'docker logs job_db'"
    fi
done

# Create a backup directory
if [ ! -d "backups" ]; then
    mkdir -p backups
    success "Created backups directory"
fi

# Run a backup before applying migrations (if database already has data)
section "Database Backup"
echo "Checking if database has existing data..."
table_count=$(docker exec job_db psql -U jobuser -d jobsdb -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'" | tr -d '[:space:]')

if [ "$table_count" -gt "0" ]; then
    echo "Found existing tables. Creating a backup before proceeding..."
    backup_file="backups/jobsdb_backup_$(date +%Y%m%d_%H%M%S).sql"
    docker exec job_db pg_dump -U jobuser -d jobsdb > "$backup_file"
    success "Created backup at $backup_file"
else
    success "New database - no backup needed"
fi

# Run migrations directly
section "Running Migrations"
echo "Applying database migrations..."

# Check if migration files exist
migration_files=("01_create_normalized_schema.sql" "02_migrate_data.sql" "03_create_materialized_views.sql" "04_setup_partitioning.sql" "05_modify_database_access.sql")
missing_files=()

for file in "${migration_files[@]}"; do
    if [ ! -f "migrations/$file" ]; then
        missing_files+=("$file")
    fi
done

if [ ${#missing_files[@]} -gt 0 ]; then
    warning "The following migration files are missing:"
    for file in "${missing_files[@]}"; do
        echo "  - $file"
    done
    read -p "Do you want to continue with the available migration files? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        error "Migration aborted. Please add the missing files and try again."
    fi
fi

# Copy migration files to the container
echo "Ensuring migration files are available in the container..."
docker exec job_db bash -c "mkdir -p /tmp/migrations"
for migration_file in migrations/*.sql; do
    if [ -f "$migration_file" ]; then
        filename=$(basename "$migration_file")
        docker cp "$migration_file" job_db:/tmp/migrations/
        success "Copied $filename to container"
    fi
done

# Function to run a SQL migration file
run_migration() {
    local file=$1
    if [ -f "migrations/$file" ]; then
        echo "Running migration: $file"
        docker exec job_db bash -c "PGPASSWORD=\$(cat /run/secrets/db_password || echo '$(cat secrets/db_password.txt)') psql -U jobuser -d jobsdb -f /tmp/migrations/$file"
        success "Applied $file"
    else
        warning "Skipping $file (not found)"
    fi
}

# Execute migrations in correct order with error handling
echo "Executing migration scripts..."
for file in "${migration_files[@]}"; do
    if run_migration "$file"; then
        continue
    else
        warning "Error during migration $file. Check the logs for details."
        read -p "Do you want to continue with the next migration? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Migration process aborted."
        fi
    fi
done

success "Database migrations applied"

section "Next Steps"
echo "Database is now running with the normalized schema."
echo ""
echo "To connect to the database:"
echo "  Host: localhost"
echo "  Port: 5432"
echo "  Database: jobsdb"
echo "  Username: jobuser"
echo "  Password: $(cat secrets/db_password.txt)"
echo ""
echo "To start the full application:"
echo "  Run './install.sh'"
echo ""
echo "To verify migrations:"
echo "  Run: docker exec -it job_db psql -U jobuser -d jobsdb -c 'SELECT COUNT(*) FROM companies;'"
echo ""
echo "To restore from backup (if needed):"
echo "  Run: cat backups/your_backup_file.sql | docker exec -i job_db psql -U jobuser -d jobsdb" 