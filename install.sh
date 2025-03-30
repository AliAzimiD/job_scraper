#!/bin/bash
set -e

# Installation script for job_scraper with normalized database schema
# This script sets up the job_scraper with the optimized database structure
# Using a two-phase approach to avoid Docker Compose issues

# Get script directory - for proper path resolution regardless of where script is called from
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}" # Ensure we're in the right directory

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration with defaults - can be overridden with environment variables
: "${DB_PASSWORD:=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)}"
: "${PGADMIN_EMAIL:=admin@example.com}"
: "${PGADMIN_PASSWORD:=admin123secure}"
: "${SUPERSET_ADMIN_PASSWORD:=admin123secure}"
: "${ENABLE_SUPERSET:=true}"
: "${ENABLE_PGADMIN:=true}"
: "${ENABLE_SCRAPER:=true}"
: "${INSTALLATION_MODE:=full}" # full, minimal, or custom

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
        if [ -f "${SCRIPT_DIR}/scripts/cleanup.sh" ]; then
            "${SCRIPT_DIR}/scripts/cleanup.sh"
        elif [ -f "${SCRIPT_DIR}/cleanup.sh" ]; then
            "${SCRIPT_DIR}/cleanup.sh"
        else
            warning "Cleanup script not found"
        fi
    fi
    
    error "Installation failed: $error_message"
}

# Print installation mode information
print_mode_info() {
    section "Installation Mode: ${INSTALLATION_MODE}"
    case "${INSTALLATION_MODE}" in
        full)
            echo "Full installation with all components:"
            echo "- Database"
            echo "- Job Scraper"
            echo "- PgAdmin"
            echo "- Superset"
            ;;
        minimal)
            echo "Minimal installation with essential components:"
            echo "- Database"
            echo "- PgAdmin"
            ENABLE_SUPERSET=false
            ENABLE_SCRAPER=false
            ;;
        custom)
            echo "Custom installation with selected components:"
            echo "- Database (always enabled)"
            [ "${ENABLE_PGADMIN}" = "true" ] && echo "- PgAdmin"
            [ "${ENABLE_SCRAPER}" = "true" ] && echo "- Job Scraper"
            [ "${ENABLE_SUPERSET}" = "true" ] && echo "- Superset"
            ;;
        *)
            warning "Unknown installation mode: ${INSTALLATION_MODE}"
            echo "Defaulting to full installation"
            INSTALLATION_MODE=full
            ;;
    esac
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
    
    # Check git
    if command_exists git; then
        success "Git is installed"
    else
        warning "Git is not installed. It's recommended for updating the project."
    fi
    
    # Check directory structure with organized directories
    MIGRATIONS_DIR="${SCRIPT_DIR}/migrations"
    INIT_DB_DIR="${SCRIPT_DIR}/init-db"
    SECRETS_DIR="${SCRIPT_DIR}/secrets"
    JOB_DATA_DIR="${SCRIPT_DIR}/job_data"
    CONFIG_DIR="${SCRIPT_DIR}/config"
    SUPERSET_DIR="${SCRIPT_DIR}/superset"
    SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
    DOCKER_DIR="${SCRIPT_DIR}/docker"
    
    # Create necessary directories
    for dir in "$MIGRATIONS_DIR" "$INIT_DB_DIR" "$SECRETS_DIR" "$JOB_DATA_DIR" "$CONFIG_DIR" "$SUPERSET_DIR" "$SCRIPTS_DIR" "$DOCKER_DIR"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            warning "Created $dir directory"
        fi
    done
    
    # Check if migration files exist
    migration_files=("01_create_normalized_schema.sql" "02_migrate_data.sql" "03_create_materialized_views.sql")
    missing_files=()
    
    for file in "${migration_files[@]}"; do
        if [ ! -f "${MIGRATIONS_DIR}/$file" ]; then
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
    
    success "All prerequisites met"
}

# Setup secrets
setup_secrets() {
    section "Setting Up Secrets"
    
    # Track created files
    files_created=0
    
    # Create database password if it doesn't exist
    if [ ! -f "${SECRETS_DIR}/db_password.txt" ]; then
        echo "$DB_PASSWORD" > "${SECRETS_DIR}/db_password.txt"
        ((files_created++))
    fi
    
    # Create pgAdmin credentials
    if [ ! -f "${SECRETS_DIR}/pgadmin_email.txt" ]; then
        echo "$PGADMIN_EMAIL" > "${SECRETS_DIR}/pgadmin_email.txt"
        ((files_created++))
    fi
    
    if [ ! -f "${SECRETS_DIR}/pgadmin_password.txt" ]; then
        echo "$PGADMIN_PASSWORD" > "${SECRETS_DIR}/pgadmin_password.txt"
        ((files_created++))
    fi
    
    # Create Superset credentials
    if [ ! -f "${SECRETS_DIR}/superset_secret_key.txt" ]; then
        SUPERSET_KEY=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 32 | head -n 1)
        echo "$SUPERSET_KEY" > "${SECRETS_DIR}/superset_secret_key.txt"
        ((files_created++))
    fi
    
    if [ ! -f "${SECRETS_DIR}/superset_admin_password.txt" ]; then
        echo "$SUPERSET_ADMIN_PASSWORD" > "${SECRETS_DIR}/superset_admin_password.txt"
        ((files_created++))
    fi
    
    # Set appropriate permissions
    chmod 600 ${SECRETS_DIR}/*.txt
    
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
    if [ ! -f "${SUPERSET_DIR}/Dockerfile" ]; then
        cat > "${SUPERSET_DIR}/Dockerfile" << 'EOF'
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
    if [ ! -f "${SUPERSET_DIR}/superset_config.py" ]; then
        cat > "${SUPERSET_DIR}/superset_config.py" << 'EOF'
"""Superset configuration file for job_scraper."""
import os
import secrets

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

# Get secrets from environment or defaults
SECRET_KEY = os.environ.get('SUPERSET_SECRET_KEY', 'superset_secret_key_value')
if SECRET_KEY == 'superset_secret_key_value':
    # Generate a secure secret key if using the default
    SECRET_KEY = secrets.token_urlsafe(32)

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
    
    success "Superset files created successfully"
}

# Clean up Docker resources (if requested)
cleanup_resources() {
    section "Cleaning up Docker Resources"
    
    # Check if cleanup script exists in scripts dir or in current dir
    if [ -f "${SCRIPT_DIR}/scripts/cleanup.sh" ]; then
        echo "Running cleanup script from scripts directory..."
        "${SCRIPT_DIR}/scripts/cleanup.sh"
    elif [ -f "${SCRIPT_DIR}/cleanup.sh" ]; then
        echo "Running cleanup script from current directory..."
        "${SCRIPT_DIR}/cleanup.sh"
    else
        warning "Cleanup script not found, performing manual cleanup"
        
        # Stop and remove containers
        echo "Stopping any existing containers..."
        docker-compose down -v 2>/dev/null || true
        
        # Remove all job_* containers that might be left
        for container in $(docker ps -a | grep job_ | awk '{print $1}'); do
            echo "Removing container $(docker inspect --format='{{.Name}}' $container 2>/dev/null || echo $container)..."
            docker stop $container 2>/dev/null || true
            docker rm -f $container 2>/dev/null || true
        done
        
        # Remove volumes
        for volume in job_postgres_data job_pgadmin_data job_superset_home; do
            if docker volume ls | grep -q "$volume"; then
                echo "Removing volume $volume..."
                docker volume rm $volume 2>/dev/null || true
            fi
        done
        
        # Remove networks
        for network in $(docker network ls | grep job_scraper | awk '{print $1}'); do
            echo "Removing network $(docker network inspect --format='{{.Name}}' $network 2>/dev/null || echo $network)..."
            docker network rm $network 2>/dev/null || true
        done
    fi
    
    success "Docker resources cleaned up"
}

# Create docker-compose.yml
create_docker_compose() {
    section "Creating Docker Compose File"
    
    # Generate docker-compose.yml based on installation mode
    cat > "${SCRIPT_DIR}/docker-compose.yml" << EOL
version: '3.9'

services:
  # Database service
  db:
    image: postgres:15-alpine
    container_name: job_db
    restart: unless-stopped
    environment:
      POSTGRES_USER: jobuser
      POSTGRES_DB: jobsdb
      POSTGRES_PASSWORD: jobuser_password
      TZ: Asia/Tehran
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ${SCRIPT_DIR}/migrations:/docker-entrypoint-migrations
      - ${SCRIPT_DIR}/init-db:/docker-entrypoint-initdb.d
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
EOL

    # Add PgAdmin if enabled
    if [ "${ENABLE_PGADMIN}" = "true" ]; then
        cat >> "${SCRIPT_DIR}/docker-compose.yml" << EOL

  # PgAdmin (database administration tool)
  pgadmin:
    image: dpage/pgadmin4:latest
    container_name: job_pgadmin
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@example.com
      PGADMIN_DEFAULT_PASSWORD: admin_password
    volumes:
      - pgadmin_data:/var/lib/pgadmin
    networks:
      - scraper-network
    ports:
      - "5050:80"
EOL
    fi

    # Add Redis and Superset if enabled
    if [ "${ENABLE_SUPERSET}" = "true" ]; then
        cat >> "${SCRIPT_DIR}/docker-compose.yml" << EOL

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

  # Superset (analytics dashboard)
  superset:
    build:
      context: ${SCRIPT_DIR}/superset
    container_name: job_superset
    restart: unless-stopped
    depends_on:
      - db
      - redis
    command: |
      bash -c "superset db upgrade && 
      superset fab create-admin --username admin --firstname Admin --lastname User --email admin@example.com --password admin_password && 
      superset init && 
      superset run -p 8088 --with-threads --reload --debugger"
    environment:
      SUPERSET_ENV: production
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: jobuser
      DB_NAME: jobsdb
      DB_PASSWORD: jobuser_password
      REDIS_HOST: redis
      SUPERSET_SECRET_KEY: "superset_secret_key_value"
    volumes:
      - superset_home:/app/superset_home
    networks:
      - scraper-network
    ports:
      - "8088:8088"
EOL
    fi

    # Add Job Scraper if enabled
    if [ "${ENABLE_SCRAPER}" = "true" ]; then
        cat >> "${SCRIPT_DIR}/docker-compose.yml" << EOL

  # Job scraper application
  scraper:
    build:
      context: ${SCRIPT_DIR}
      dockerfile: Dockerfile
    container_name: job_scraper
    restart: unless-stopped
    depends_on:
      db:
        condition: service_healthy
    environment:
      SCRAPER_ENV: production
      TZ: Asia/Tehran
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: jobuser
      DB_NAME: jobsdb
      DB_PASSWORD: jobuser_password
      ENABLE_CRON: "true"
    volumes:
      - ${SCRIPT_DIR}/job_data:/app/data
      - ${SCRIPT_DIR}/config:/app/config
      - ${SCRIPT_DIR}/migrations:/app/migrations
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
EOL
    fi

    # Add volumes and networks
    cat >> "${SCRIPT_DIR}/docker-compose.yml" << EOL

volumes:
  postgres_data:
    name: job_postgres_data
EOL

    # Add PgAdmin volume if enabled
    if [ "${ENABLE_PGADMIN}" = "true" ]; then
        cat >> "${SCRIPT_DIR}/docker-compose.yml" << EOL
  pgadmin_data:
    name: job_pgadmin_data
EOL
    fi

    # Add Superset volume if enabled
    if [ "${ENABLE_SUPERSET}" = "true" ]; then
        cat >> "${SCRIPT_DIR}/docker-compose.yml" << EOL
  superset_home:
    name: job_superset_home
EOL
    fi

    # Add networks
    cat >> "${SCRIPT_DIR}/docker-compose.yml" << EOL

networks:
  scraper-network:
    name: job_scraper_network
EOL

    success "Created docker-compose.yml for ${INSTALLATION_MODE} installation"
}

# Setup database initialization scripts
setup_db_init() {
    section "Setting Up Database Initialization"
    
    # Create schema-update script if it doesn't exist
    if [ ! -f "${INIT_DB_DIR}/02-schema-update.sh" ]; then
        cat > "${INIT_DB_DIR}/02-schema-update.sh" << 'EOF'
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
        chmod +x "${INIT_DB_DIR}/02-schema-update.sh"
        success "Created schema update script"
    fi
    
    # Create basic init script if it doesn't exist
    if [ ! -f "${INIT_DB_DIR}/01-init.sql" ]; then
        cat > "${INIT_DB_DIR}/01-init.sql" << 'EOF'
-- Basic initialization script
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS btree_gin;

-- Create schema version table if it doesn't exist yet
CREATE TABLE IF NOT EXISTS public.schema_version (
    id SERIAL PRIMARY KEY,
    version INTEGER NOT NULL,
    description TEXT,
    applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
EOF
        success "Created basic initialization script"
    fi
}

# Start the database and wait for it to be ready
start_database() {
    section "Starting Database"
    
    # Start just the database
    echo "Starting database container..."
    docker-compose up -d db
    
    # Wait for it to be ready
    echo -n "Waiting for database to be ready"
    for i in {1..30}; do
        if docker exec job_db pg_isready -U jobuser -d jobsdb > /dev/null 2>&1; then
            echo ""
            success "Database is ready"
            break
        fi
        echo -n "."
        sleep 2
        if [ $i -eq 30 ]; then
            echo ""
            handle_error "Database did not become ready in time"
        fi
    done
}

# Start all remaining services
start_services() {
    section "Starting Services"
    
    # Start all remaining services
    if [ "${INSTALLATION_MODE}" = "minimal" ]; then
        echo "Starting minimal services (database and pgadmin)..."
        docker-compose up -d db pgadmin
    elif [ "${INSTALLATION_MODE}" = "custom" ]; then
        echo "Starting custom set of services..."
        services="db"
        [ "${ENABLE_PGADMIN}" = "true" ] && services="$services pgadmin"
        [ "${ENABLE_SUPERSET}" = "true" ] && services="$services redis superset"
        [ "${ENABLE_SCRAPER}" = "true" ] && services="$services scraper"
        
        echo "Starting services: $services"
        docker-compose up -d $services
    else
        echo "Starting all services..."
        docker-compose up -d
    fi
    
    success "Services started successfully"
}

# Print success message and access information
print_success() {
    section "Installation Completed Successfully"
    
    echo "The job_scraper system has been installed successfully."
    echo ""
    echo "Services:"
    
    # Database
    echo "- Database: PostgreSQL"
    echo "  - Host: localhost"
    echo "  - Port: 5432"
    echo "  - Database: jobsdb"
    echo "  - Username: jobuser"
    echo "  - Password: $(cat ${SECRETS_DIR}/db_password.txt)"
    echo ""
    
    # PgAdmin
    if [ "${ENABLE_PGADMIN}" = "true" ]; then
        echo "- PgAdmin: http://localhost:5050"
        echo "  - Email: $(cat ${SECRETS_DIR}/pgadmin_email.txt)"
        echo "  - Password: $(cat ${SECRETS_DIR}/pgadmin_password.txt)"
        echo ""
    fi
    
    # Superset
    if [ "${ENABLE_SUPERSET}" = "true" ]; then
        echo "- Superset: http://localhost:8088"
        echo "  - Username: admin"
        echo "  - Password: $(cat ${SECRETS_DIR}/superset_admin_password.txt)"
        echo ""
    fi
    
    # Job Scraper
    if [ "${ENABLE_SCRAPER}" = "true" ]; then
        echo "- Job Scraper API: http://localhost:8081"
        echo ""
    fi
    
    echo "To view logs for any service:"
    echo "  docker logs job_db"
    echo "  docker logs job_pgadmin"
    [ "${ENABLE_SUPERSET}" = "true" ] && echo "  docker logs job_superset"
    [ "${ENABLE_SCRAPER}" = "true" ] && echo "  docker logs job_scraper"
    echo ""
    
    echo "To stop all services:"
    echo "  docker-compose down"
    echo ""
    
    echo "To restart all services:"
    echo "  docker-compose restart"
    echo ""
    
    echo "For more information, see the README.md file."
}

# Main installation flow
main() {
    # Print banner
    section "Job Scraper Installation"
    echo "This script will install the job_scraper system with the normalized database schema."
    echo "Please make sure Docker and Docker Compose are installed and running."
    echo ""
    
    # Ask for installation mode if not set
    if [ -z "${INSTALLATION_MODE_SET}" ]; then
        echo "Select installation mode:"
        echo "1) Full - All components (database, scraper, pgadmin, superset)"
        echo "2) Minimal - Essential components only (database, pgadmin)"
        echo "3) Custom - Choose which components to install"
        echo ""
        read -p "Enter your choice [1-3, default=1]: " choice
        echo ""
        
        case "${choice}" in
            2)
                INSTALLATION_MODE=minimal
                ;;
            3)
                INSTALLATION_MODE=custom
                read -p "Enable PgAdmin? [Y/n, default=Y]: " enable_pgadmin
                [ "${enable_pgadmin}" = "n" ] || [ "${enable_pgadmin}" = "N" ] && ENABLE_PGADMIN=false
                
                read -p "Enable Job Scraper? [Y/n, default=Y]: " enable_scraper
                [ "${enable_scraper}" = "n" ] || [ "${enable_scraper}" = "N" ] && ENABLE_SCRAPER=false
                
                read -p "Enable Superset? [Y/n, default=Y]: " enable_superset
                [ "${enable_superset}" = "n" ] || [ "${enable_superset}" = "N" ] && ENABLE_SUPERSET=false
                ;;
            *)
                INSTALLATION_MODE=full
                ;;
        esac
        INSTALLATION_MODE_SET=true
    fi
    
    # Print installation mode info
    print_mode_info
    
    # Confirm installation
    echo ""
    read -p "Do you want to proceed with the installation? [Y/n, default=Y]: " proceed
    if [ "${proceed}" = "n" ] || [ "${proceed}" = "N" ]; then
        echo "Installation aborted."
        exit 0
    fi
    
    # Execute installation steps
    check_prerequisites
    setup_secrets
    
    # Setup Superset if enabled
    [ "${ENABLE_SUPERSET}" = "true" ] && setup_superset
    
    # Clean up existing resources
    read -p "Would you like to clean up existing Docker resources? [y/N, default=N]: " cleanup
    if [ "${cleanup}" = "y" ] || [ "${cleanup}" = "Y" ]; then
        cleanup_resources
    fi
    
    # Create docker-compose.yml file
    create_docker_compose
    
    # Setup database initialization scripts
    setup_db_init
    
    # Start database
    start_database
    
    # Start all other services
    start_services
    
    # Print success message
    print_success
}

# Handle SIGINT (Ctrl+C)
trap "echo -e '\nInstallation interrupted'; exit 1" SIGINT

# Run main function
main 