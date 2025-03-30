#!/bin/bash
set -e

# Fresh installation script for job_scraper with normalized database schema
# This script performs a complete cleanup and then sets up all components

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

# Print an error message and exit
error() {
    echo -e "${RED}✗ $1${NC}"
    exit 1
}

# Print a warning message
warning() {
    echo -e "${YELLOW}! $1${NC}"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to handle errors
handle_error() {
    error_msg="$1"
    container="$2"
    
    echo -e "${RED}ERROR: $error_msg${NC}"
    
    if [ -n "$container" ] && docker ps -a | grep -q "$container"; then
        echo "Last 50 lines of logs from $container:"
        docker logs --tail 50 "$container"
    fi
    
    echo ""
    echo "Installation failed. Please check the error message above."
    exit 1
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
    success "Docker is running"
    
    # Check Docker Compose
    if command_exists docker-compose; then
        success "Docker Compose is installed"
    else
        error "Docker Compose is not installed. Please install Docker Compose and try again."
    fi
    
    # Check directories
    mkdir -p migrations job_data config secrets init-db superset backups
    success "Created necessary directories"
    
    # Check if migration files exist
    if [ -z "$(ls -A migrations/*.sql 2>/dev/null)" ]; then
        warning "No SQL migration files found in migrations directory."
        warning "You will need to add migration files for a complete setup."
    else
        success "Found migration files: $(ls migrations/*.sql | wc -l) SQL file(s)"
    fi
}

# Clean up Docker resources
perform_cleanup() {
    section "Cleaning Up Docker Resources"
    echo "Stopping and removing existing Docker resources..."
    
    # Stop and remove containers using docker-compose if available
    if [ -f "docker-compose.yml" ]; then
        docker-compose down -v 2>/dev/null || true
    fi
    
    # Find and remove any remaining job_scraper-related containers
    for container in $(docker ps -a | grep "job_" | awk '{print $1}'); do
        container_name=$(docker inspect --format='{{.Name}}' $container 2>/dev/null || echo $container)
        echo "Stopping and removing container: $container_name"
        docker stop $container 2>/dev/null || true
        docker rm -f $container 2>/dev/null || true
    done
    
    # Remove volumes
    for volume in $(docker volume ls -q | grep "job_"); do
        echo "Removing volume: $volume"
        docker volume rm $volume 2>/dev/null || true
    done
    
    # Remove networks
    for network in $(docker network ls | grep "job_scraper" | awk '{print $1}'); do
        network_name=$(docker network inspect --format='{{.Name}}' $network 2>/dev/null || echo $network)
        echo "Removing network: $network_name"
        docker network rm $network 2>/dev/null || true
    done
    
    success "Cleanup completed"
}

# Set up secrets
setup_secrets() {
    section "Setting Up Secrets"
    
    # Create database password
    DB_PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
    echo "$DB_PASSWORD" > secrets/db_password.txt
    
    # Create pgAdmin credentials
    echo "admin@example.com" > secrets/pgadmin_email.txt
    echo "admin$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)" > secrets/pgadmin_password.txt
    
    # Create Superset credentials
    SUPERSET_KEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
    echo "$SUPERSET_KEY" > secrets/superset_secret_key.txt
    
    echo "admin$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 8 | head -n 1)" > secrets/superset_admin_password.txt
    
    # Set appropriate permissions
    chmod 600 secrets/*.txt
    
    success "Created secret files with secure credentials"
}

# Set up Superset files
setup_superset() {
    section "Setting Up Superset"
    
    # Create Superset directory if it doesn't exist
    mkdir -p superset
    
    # Create Superset Dockerfile
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
    redis==4.5.5 \
    PyAthena==2.25.2

# Copy configuration
COPY superset_config.py /app/pythonpath/

USER superset
EOF
    
    # Create Superset config file
    cat > superset/superset_config.py << 'EOF'
"""Superset configuration file for job_scraper."""
import os
from datetime import timedelta

# Function to get password from file
def get_password_from_file(file_path, default=''):
    if os.path.exists(file_path):
        with open(file_path, 'r') as f:
            return f.read().strip()
    return default

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

# Get secrets from files
DB_PASSWORD_FILE = os.environ.get('DB_PASSWORD_FILE', '/run/secrets/db_password')
DB_PASSWORD = get_password_from_file(DB_PASSWORD_FILE)
SUPERSET_SECRET_KEY_FILE = os.environ.get('SUPERSET_SECRET_KEY_FILE', '/run/secrets/superset_secret_key')
SECRET_KEY = get_password_from_file(SUPERSET_SECRET_KEY_FILE)

# Database connection
DB_USER = os.environ.get('DB_USER', 'jobuser')
DB_HOST = os.environ.get('DB_HOST', 'db')
DB_PORT = os.environ.get('DB_PORT', '5432')
DB_NAME = os.environ.get('DB_NAME', 'jobsdb')

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
    
    success "Superset configuration files created"
}

# Setup database initialization scripts
setup_init_db() {
    section "Setting Up Database Initialization Scripts"
    
    # Create schema update script
    cat > init-db/02-schema-update.sh << 'EOF'
#!/bin/bash
set -e

# This script runs during PostgreSQL initialization to apply schema migrations

echo "Checking if schema upgrade is needed..."

# Get PostgreSQL connection details
PGDB=${POSTGRES_DB:-jobsdb}
PGUSER=${POSTGRES_USER:-jobuser}

# Check if schema_version table exists
SCHEMA_EXISTS=$(psql -U "$PGUSER" -d "$PGDB" -t -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'schema_version')")

if [[ $SCHEMA_EXISTS == *"t"* ]]; then
    echo "Schema version table exists, skipping initial migration"
    exit 0
fi

echo "Performing initial schema migration..."

# Apply migration scripts in order if they exist
for MIGRATION_FILE in /docker-entrypoint-migrations/*.sql; do
    if [ -f "$MIGRATION_FILE" ]; then
        echo "Applying migration: $MIGRATION_FILE"
        psql -U "$PGUSER" -d "$PGDB" -f "$MIGRATION_FILE" || echo "Warning: Error applying $MIGRATION_FILE"
    fi
done

# Create schema_version table
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
    success "Database initialization script created"
}

# Start and apply migrations to database
start_database() {
    section "Starting Database and Applying Migrations"
    
    echo "Starting database service..."
    if ! docker-compose up -d db; then
        handle_error "Failed to start database service" "job_db"
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
            handle_error "Database did not become ready in time" "job_db"
        fi
    done
    
    # Execute migrations with the migrator service
    echo "Running migration service..."
    if ! docker-compose --profile migrations up -d migrator; then
        handle_error "Failed to start migration service" "job_migrator"
    fi
    
    # Wait for migrations to complete
    echo "Waiting for migrations to complete..."
    sleep 5
    
    # Check migrator logs
    docker logs job_migrator
    
    # Check if migrator has completed successfully
    if ! docker logs job_migrator 2>&1 | grep -q "Migrations completed successfully"; then
        warning "Migrations may not have completed successfully. Check the logs above for errors."
        
        read -p "Continue with installation anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            error "Installation aborted by user."
        fi
    else
        success "Migrations completed successfully"
    fi
}

# Start all remaining services
start_services() {
    section "Starting Remaining Services"
    
    # Start Redis
    echo "Starting Redis service..."
    if ! docker-compose up -d redis; then
        handle_error "Failed to start Redis service" "job_redis"
    fi
    success "Redis service started"
    
    # Start pgAdmin
    echo "Starting pgAdmin service..."
    if ! docker-compose up -d pgadmin; then
        handle_error "Failed to start pgAdmin service" "job_pgadmin"
    fi
    success "pgAdmin service started"
    
    # Start Superset (with build)
    echo "Building and starting Superset service..."
    if ! docker-compose up -d --build superset; then
        handle_error "Failed to start Superset service" "job_superset"
    fi
    success "Superset service started"
    
    # Start scraper if Dockerfile exists
    if [ -f "Dockerfile" ]; then
        echo "Building and starting scraper service..."
        if ! docker-compose up -d --build scraper; then
            warning "Failed to start scraper service. This may be because the Dockerfile is missing or incorrect."
        else
            success "Scraper service started"
        fi
    else
        warning "Skipping scraper service as Dockerfile is missing"
    fi
    
    # Wait a moment for services to initialize
    echo "Waiting for services to initialize..."
    sleep 10
    
    # Show container status
    docker-compose ps
}

# Display connection information
show_info() {
    section "Installation Complete"
    
    echo "The job_scraper system has been installed with the normalized database schema."
    echo ""
    echo "Services:"
    echo "- Job Scraper API: http://localhost:8081"
    echo "- PgAdmin: http://localhost:5050"
    echo "  - Email: $(cat secrets/pgadmin_email.txt)"
    echo "  - Password: $(cat secrets/pgadmin_password.txt)"
    echo "- Superset: http://localhost:8088"
    echo "  - Username: admin"
    echo "  - Password: $(cat secrets/superset_admin_password.txt)"
    echo ""
    echo "Database Connection:"
    echo "- Host: localhost"
    echo "- Port: 5432"
    echo "- Database: jobsdb"
    echo "- Username: jobuser"
    echo "- Password: $(cat secrets/db_password.txt)"
    echo ""
    echo "Troubleshooting:"
    echo "- View container logs: docker logs [container_name]"
    echo "- Restart all services: docker-compose restart"
    echo "- Check container status: docker-compose ps"
    echo "- Connect to database: docker exec -it job_db psql -U jobuser -d jobsdb"
    echo ""
    echo "For more information, see QUICK_START.md"
}

# Main installation flow
main() {
    section "Fresh Job Scraper Installation"
    echo "This will perform a clean installation of the job_scraper system."
    echo "WARNING: All existing data will be removed."
    
    # Ask for confirmation
    read -p "Would you like to proceed with the installation? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Installation aborted."
        exit 0
    fi
    
    # Start installation
    check_prerequisites
    perform_cleanup
    setup_secrets
    setup_superset
    setup_init_db
    start_database
    start_services
    show_info
}

# Handle script interruptions
trap 'echo -e "\n${RED}Installation interrupted. You may need to run ./cleanup.sh to clean up.${NC}"; exit 1' INT

# Run the installation
main 