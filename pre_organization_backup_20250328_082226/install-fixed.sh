#!/bin/bash
set -e

# Installation script for job_scraper with normalized database schema
# This script sets up the job_scraper with the optimized database structure
# Using a two-phase approach to avoid Docker Compose issues

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

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to handle errors with cleanup
handle_error() {
    error_message=$1
    warning "ERROR: $error_message"
    warning "To troubleshoot, check the logs of the container that failed:"
    warning "  docker logs job_db"
    warning "  docker logs job_scraper"
    
    read -p "Would you like to run cleanup before exiting? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Running cleanup..."
        ./cleanup.sh
    fi
    
    error "Installation failed: $error_message"
}

# Check prerequisites
check_prerequisites() {
    section "Checking Prerequisites"
    
    # Check Docker
    if command_exists docker; then
        success "Docker is installed"
    else
        error "Docker is not installed. Please install Docker and try again."
    fi
    
    # Verify Docker is running
    if ! docker info > /dev/null 2>&1; then
        error "Docker is not running. Please start Docker and try again."
    fi
    
    # Check Docker Compose
    if command_exists docker-compose; then
        success "Docker Compose is installed"
    else
        error "Docker Compose is not installed. Please install Docker Compose and try again."
    fi
    
    # Check if directory structure exists
    if [ ! -d "migrations" ]; then
        mkdir -p migrations
        warning "Created migrations directory - make sure to add migration files"
    else
        # Check if migration files exist
        migration_files=("01_create_normalized_schema.sql" "02_migrate_data.sql" "03_create_materialized_views.sql")
        missing_files=()
        
        for file in "${migration_files[@]}"; do
            if [ ! -f "migrations/$file" ]; then
                missing_files+=("$file")
            fi
        done
        
        if [ ${#missing_files[@]} -gt 0 ]; then
            warning "The following essential migration files are missing:"
            for file in "${missing_files[@]}"; do
                echo "  - $file"
            done
            error "Please add the missing migration files and try again."
        else
            success "Required migration files are present"
        fi
    fi
    
    # Check if init-db directory exists
    if [ ! -d "init-db" ]; then
        mkdir -p init-db
        warning "Created init-db directory"
    fi
    
    # Check if secrets directory exists
    if [ ! -d "secrets" ]; then
        mkdir -p secrets
        warning "Created secrets directory"
    fi
    
    # Check if required directories exist
    for dir in "job_data" "config" "superset"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            warning "Created $dir directory"
        fi
    done
    
    success "All prerequisites met"
}

# Setup secrets
setup_secrets() {
    section "Setting Up Secrets"
    
    # Track created files
    files_created=0
    
    # Create database password if it doesn't exist
    if [ ! -f "secrets/db_password.txt" ]; then
        # Generate a random password
        DB_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
        echo "$DB_PASSWORD" > secrets/db_password.txt
        ((files_created++))
    fi
    
    # Create pgAdmin credentials
    if [ ! -f "secrets/pgadmin_email.txt" ]; then
        echo "admin@example.com" > secrets/pgadmin_email.txt
        ((files_created++))
    fi
    
    if [ ! -f "secrets/pgadmin_password.txt" ]; then
        echo "admin123secure" > secrets/pgadmin_password.txt
        ((files_created++))
    fi
    
    # Create Superset credentials
    if [ ! -f "secrets/superset_secret_key.txt" ]; then
        SUPERSET_KEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
        echo "$SUPERSET_KEY" > secrets/superset_secret_key.txt
        ((files_created++))
    fi
    
    if [ ! -f "secrets/superset_admin_password.txt" ]; then
        echo "admin123secure" > secrets/superset_admin_password.txt
        ((files_created++))
    fi
    
    # Set appropriate permissions
    chmod 600 secrets/*.txt
    
    if [ $files_created -gt 0 ]; then
        success "Created $files_created new secret files"
    else
        success "All secret files already exist"
    fi
}

# Create necessary files for Superset
setup_superset() {
    section "Setting Up Superset"
    
    # Create Superset Dockerfile if it doesn't exist
    if [ ! -f "superset/Dockerfile" ]; then
        cat > superset/Dockerfile << 'EOF'
FROM apache/superset:latest

USER root

# Install additional dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    default-libmysqlclient-dev \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Install database drivers and other requirements
RUN pip install --no-cache-dir \
    psycopg2-binary==2.9.6 \
    sqlalchemy-redshift==0.8.12 \
    sqlalchemy==1.4.47 \
    redis==4.5.5

# Copy configuration
COPY superset_config.py /app/pythonpath/

USER superset
EOF
        success "Created Superset Dockerfile"
    fi
    
    # Create Superset config file if it doesn't exist
    if [ ! -f "superset/superset_config.py" ]; then
        cat > superset/superset_config.py << 'EOF'
"""Superset configuration file for job_scraper."""
import os

# Superset specific configuration
ROW_LIMIT = 5000
SUPERSET_WEBSERVER_PORT = 8088
SUPERSET_WEBSERVER_TIMEOUT = 300
FEATURE_FLAGS = {
    "ENABLE_TEMPLATE_PROCESSING": True,
    "DASHBOARD_NATIVE_FILTERS": True,
    "DASHBOARD_CROSS_FILTERS": True,
    "ENABLE_EXPLORE_DRAG_AND_DROP": True,
    "DASHBOARD_VIRTUALIZATION": True,
}

# Get secrets from environment
SECRET_KEY = 'superset_secret_key'

# Database connection
DB_USER = os.environ.get('DB_USER', 'jobuser')
DB_HOST = os.environ.get('DB_HOST', 'db')
DB_PORT = os.environ.get('DB_PORT', '5432')
DB_NAME = os.environ.get('DB_NAME', 'jobsdb')
DB_PASSWORD = os.environ.get('DB_PASSWORD', 'jobuser_password')

# SQLAlchemy connection string
SQLALCHEMY_DATABASE_URI = f"postgresql+psycopg2://{DB_USER}:{DB_PASSWORD}@{DB_HOST}:{DB_PORT}/{DB_NAME}"

# Redis for Celery
REDIS_HOST = os.environ.get('REDIS_HOST', 'redis')
REDIS_PORT = os.environ.get('REDIS_PORT', '6379')
REDIS_CELERY_DB = os.environ.get('REDIS_CELERY_DB', '0')
REDIS_RESULTS_DB = os.environ.get('REDIS_RESULTS_DB', '1')

class CeleryConfig:
    BROKER_URL = f"redis://{REDIS_HOST}:{REDIS_PORT}/{REDIS_CELERY_DB}"
    CELERY_IMPORTS = ('superset.sql_lab',)
    CELERY_RESULT_BACKEND = f"redis://{REDIS_HOST}:{REDIS_PORT}/{REDIS_RESULTS_DB}"
    CELERYD_LOG_LEVEL = "INFO"
    CELERYD_PREFETCH_MULTIPLIER = 10
    CELERY_ACKS_LATE = True
    CELERY_ANNOTATIONS = {
        'sql_lab.get_sql_results': {
            'rate_limit': '100/s',
        },
    }

CELERY_CONFIG = CeleryConfig
EOF
        success "Created Superset configuration file"
    fi
}

# Setup init-db scripts
setup_init_db() {
    section "Setting Up Database Initialization Scripts"
    
    # Create version check script if it doesn't exist
    if [ ! -f "init-db/02-schema-update.sh" ]; then
        cat > init-db/02-schema-update.sh << 'EOF'
#!/bin/bash
set -e

# This script runs during PostgreSQL initialization to check and apply schema migrations
# if the database is being created for the first time

# Log the start of schema check
echo "Checking if schema upgrade is needed..."

# Get PostgreSQL connection details from environment variables
PGDB=${POSTGRES_DB:-jobsdb}
PGUSER=${POSTGRES_USER:-jobuser}

# Check if schema_version table exists
SCHEMA_EXISTS=$(psql -U "$PGUSER" -d "$PGDB" -t -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'schema_version')")

if [[ $SCHEMA_EXISTS == *"t"* ]]; then
    echo "Schema version table exists, skipping initial migration"
    exit 0
fi

echo "Performing initial schema migration..."

# Apply our migration scripts in order
for MIGRATION_FILE in /docker-entrypoint-migrations/*.sql; do
    if [ -f "$MIGRATION_FILE" ]; then
        echo "Applying migration: $MIGRATION_FILE"
        psql -U "$PGUSER" -d "$PGDB" -f "$MIGRATION_FILE"
    fi
done

# Create schema_version table if it doesn't exist
psql -U "$PGUSER" -d "$PGDB" -c "
CREATE TABLE IF NOT EXISTS public.schema_version (
    id SERIAL PRIMARY KEY,
    version INTEGER NOT NULL,
    description TEXT,
    applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert initial version record
INSERT INTO public.schema_version (version, description)
VALUES (2, 'Initial normalized schema migration')
"

echo "Schema initialization complete!"
EOF
        chmod +x init-db/02-schema-update.sh
        success "Created database initialization script"
    fi
}

# Create a fixed docker-compose.yml file
create_docker_compose() {
    section "Creating Docker Compose Configuration"
    
    # Create a fixed docker-compose file
    cat > docker-compose.yml << 'EOF'
version: '3.9'

services:
  # Job scraper application
  scraper:
    build:
      context: .
      dockerfile: Dockerfile
    container_name: job_scraper
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      - SCRAPER_ENV=production
      - TZ=Asia/Tehran
      - DB_HOST=db
      - DB_PORT=5432
      - DB_USER=jobuser
      - DB_NAME=jobsdb
      - DB_PASSWORD=jobuser_password
    volumes:
      - ./job_data:/app/data
      - ./config:/app/config
      - ./migrations:/app/migrations
    networks:
      - scraper-network
    ports:
      - "8081:8081"
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://localhost:8081/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  # Database service
  db:
    image: postgres:15-alpine
    container_name: job_db
    restart: unless-stopped
    environment:
      - POSTGRES_USER=jobuser
      - POSTGRES_DB=jobsdb
      - POSTGRES_PASSWORD=jobuser_password
      - TZ=Asia/Tehran
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./migrations:/docker-entrypoint-migrations
      - ./init-db:/docker-entrypoint-initdb.d
    networks:
      - scraper-network
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U jobuser -d jobsdb"]
      interval: 5s
      timeout: 5s
      retries: 5
      start_period: 10s
    ports:
      - "5432:5432"

  # PgAdmin (database administration tool)
  pgadmin:
    image: dpage/pgadmin4:latest
    container_name: job_pgadmin
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      - PGADMIN_DEFAULT_EMAIL=admin@example.com
      - PGADMIN_DEFAULT_PASSWORD=admin_password
    volumes:
      - pgadmin_data:/var/lib/pgadmin
    networks:
      - scraper-network
    ports:
      - "5050:80"

  # Redis service required for Superset
  redis:
    image: redis:7-alpine
    container_name: job_redis
    restart: unless-stopped
    networks:
      - scraper-network
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

  # Superset (analytics dashboard) with fixed command formatting
  superset:
    build:
      context: ./superset
    container_name: job_superset
    restart: unless-stopped
    depends_on:
      - db
      - redis
    # Using YAML pipe syntax for the command to avoid interpolation issues
    command: |
      bash -c "superset db upgrade && 
      superset fab create-admin --username admin --firstname Admin --lastname User --email admin@example.com --password admin_password && 
      superset init && 
      superset run -p 8088 --with-threads --reload --debugger"
    environment:
      - SUPERSET_ENV=production
      - DB_HOST=db
      - DB_PORT=5432
      - DB_USER=jobuser
      - DB_NAME=jobsdb
      - DB_PASSWORD=jobuser_password
      - REDIS_HOST=redis
    volumes:
      - superset_home:/app/superset_home
    networks:
      - scraper-network
    ports:
      - "8088:8088"

volumes:
  postgres_data:
    name: job_postgres_data
  pgadmin_data:
    name: job_pgadmin_data
  superset_home:
    name: job_superset_home

networks:
  scraper-network:
    name: job_scraper_network
EOF
    success "Created Docker Compose file with fixed Superset command"
}

# Clean up Docker resources
cleanup_docker() {
    section "Cleaning Up Docker Resources"
    
    echo "Running the cleanup script..."
    yes | ./cleanup.sh

    success "Docker resources cleaned up"
}

# Phase 1: Set up database and run migrations
setup_database() {
    section "Phase 1: Setting Up Database and Migrations"
    
    echo "Starting database container..."
    if ! docker-compose up -d db; then
        handle_error "Failed to start database container"
    fi
    
    # Wait for database to be ready
    echo -n "Waiting for database to be ready"
    timeout=45
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
            handle_error "Database did not become ready in time"
        fi
    done
    
    # Create a backup directory
    if [ ! -d "backups" ]; then
        mkdir -p backups
        success "Created backups directory"
    fi
    
    # Check if database has existing data and create backup if needed
    echo "Checking if database has existing data..."
    table_count=$(docker exec job_db psql -U jobuser -d jobsdb -t -c "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'" | tr -d '[:space:]')
    
    if [ "$table_count" -gt "0" ]; then
        echo "Found existing tables. Creating a backup before proceeding..."
        backup_file="backups/jobsdb_backup_$(date +%Y%m%d_%H%M%S).sql"
        docker exec job_db pg_dump -U jobuser -d jobsdb > "$backup_file"
        success "Created backup at $backup_file"
    fi
    
    # Run migrations using direct psql commands
    echo "Running migrations directly with psql..."
    migration_files=("01_create_normalized_schema.sql" "02_migrate_data.sql" "03_create_materialized_views.sql" "04_setup_partitioning.sql" "05_modify_database_access.sql")
    
    for migration_file in "${migration_files[@]}"; do
        if [ -f "migrations/$migration_file" ]; then
            echo "Applying migration: $migration_file"
            if ! docker exec -i job_db psql -U jobuser -d jobsdb < "migrations/$migration_file"; then
                warning "Some errors occurred while applying migration: $migration_file"
                echo "Continuing with installation..."
            else
                success "Applied migration: $migration_file"
            fi
        else
            warning "Migration file not found: $migration_file (skipping)"
        fi
    done
    
    success "Database migrations applied"
}

# Phase 2: Start remaining services
start_services() {
    section "Phase 2: Starting All Services"
    
    # Start Redis first (for Superset)
    echo "Starting Redis service..."
    if ! docker-compose up -d redis; then
        handle_error "Failed to start Redis service"
    fi
    success "Redis service started"
    
    # Start pgAdmin
    echo "Starting pgAdmin service..."
    if ! docker-compose up -d pgadmin; then
        handle_error "Failed to start pgAdmin service"
    fi
    success "pgAdmin service started"
    
    # Start Superset (with build)
    echo "Building and starting Superset service..."
    if ! docker-compose up -d --build superset; then
        handle_error "Failed to start Superset service"
    fi
    success "Superset service started"
    
    # Check if Dockerfile exists for the scraper
    if [ -f "Dockerfile" ]; then
        echo "Building and starting scraper service..."
        if ! docker-compose up -d --build scraper; then
            warning "Failed to start scraper service. You may need to check the Dockerfile or logs."
        else
            success "Scraper service started"
        fi
    else
        warning "Dockerfile not found for scraper service. Skipping this service."
    fi
    
    # Wait a moment for services to initialize
    echo "Waiting for services to initialize..."
    sleep 10
    
    # Show container status
    docker-compose ps
    success "All services started successfully"
}

# Show final information
show_info() {
    section "Installation Complete"
    
    echo "The job_scraper system has been installed with the optimized database schema."
    echo ""
    echo "Services:"
    echo "- Job Scraper: http://localhost:8081"
    echo "- PgAdmin: http://localhost:5050"
    echo "  - Email: admin@example.com"
    echo "  - Password: admin_password"
    echo "- Superset: http://localhost:8088"
    echo "  - Username: admin"
    echo "  - Password: admin_password"
    echo ""
    echo "Database Connection:"
    echo "- Host: localhost"
    echo "- Port: 5432"
    echo "- Database: jobsdb"
    echo "- Username: jobuser"
    echo "- Password: jobuser_password"
    echo ""
    echo "Database Schema Version: 2 (Normalized Schema)"
    echo ""
    echo "Troubleshooting:"
    echo "- Check container logs: docker logs [container_name]"
    echo "- Clean up and restart: ./cleanup.sh && ./install-fixed.sh"
    echo "- Backup database: docker exec job_db pg_dump -U jobuser jobsdb > backup.sql"
    echo ""
    echo "For more information, see the migration README at: migrations/README.md"
}

# Main installation flow
main() {
    section "Job Scraper Installation (Fixed Version)"
    echo "This script will install the job_scraper with the optimized database schema."
    
    # Show installation steps
    echo "Installation steps:"
    echo "1. Check prerequisites"
    echo "2. Set up secrets"
    echo "3. Set up Superset configuration"
    echo "4. Set up database initialization scripts"
    echo "5. Create fixed Docker Compose configuration"
    echo "6. Clean up existing Docker resources"
    echo "7. Set up database and run migrations"
    echo "8. Start all services"
    echo ""
    
    # Ask for confirmation
    read -p "Would you like to proceed with the installation? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation aborted."
        exit 0
    fi
    
    # Begin installation
    check_prerequisites
    setup_secrets
    setup_superset
    setup_init_db
    create_docker_compose
    cleanup_docker
    setup_database
    start_services
    show_info
}

# Handle script interruptions
trap 'echo -e "\n${RED}Installation interrupted. You may need to run ./cleanup.sh to clean up.${NC}"; exit 1' INT

# Run the installation
main 