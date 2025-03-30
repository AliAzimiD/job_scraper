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

section "Job Scraper Complete Setup"
echo "This script sets up all components of the job scraper system with proper configurations."

# Run cleanup first to ensure a clean environment
section "Cleaning up previous installations"
yes | ./cleanup.sh

# Create directories if they don't exist
section "Creating necessary directories"
mkdir -p job_data config migrations init-db superset secrets backups
success "Created necessary directories"

# Create required secret files
section "Setting up secrets"
echo "jobuser_password" > secrets/db_password.txt
echo "admin@example.com" > secrets/pgadmin_email.txt
echo "admin_password" > secrets/pgadmin_password.txt
echo "superset_secret_key_value" > secrets/superset_secret_key.txt
echo "admin_password" > secrets/superset_admin_password.txt
# Set appropriate permissions
chmod 600 secrets/*.txt
success "Created secret files"

# Create a proper Docker Compose file
section "Creating Docker Compose file"
cat > docker-compose.yml << EOF
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
      SCRAPER_ENV: production
      TZ: Asia/Tehran
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: jobuser
      DB_NAME: jobsdb
      DB_PASSWORD: jobuser_password
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
      POSTGRES_USER: jobuser
      POSTGRES_DB: jobsdb
      POSTGRES_PASSWORD: jobuser_password
      TZ: Asia/Tehran
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
      PGADMIN_DEFAULT_EMAIL: admin@example.com
      PGADMIN_DEFAULT_PASSWORD: admin_password
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

  # Superset (analytics dashboard)
  superset:
    build:
      context: ./superset
    container_name: job_superset
    restart: unless-stopped
    depends_on:
      - db
      - redis
    command: bash -c "superset db upgrade && superset fab create-admin --username admin --firstname Admin --lastname User --email admin@example.com --password admin_password && superset init && superset run -p 8088 --with-threads --reload --debugger"
    environment:
      SUPERSET_ENV: production
      DB_HOST: db
      DB_PORT: 5432
      DB_USER: jobuser
      DB_NAME: jobsdb
      DB_PASSWORD: jobuser_password
      REDIS_HOST: redis
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
success "Created Docker Compose file"

# Set up Superset
section "Setting up Superset"
mkdir -p superset
cat > superset/Dockerfile << 'EOL'
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
EOL

cat > superset/superset_config.py << 'EOL'
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
EOL
success "Superset files created"

# First start just the database to ensure migrations run correctly
section "Starting database"
docker-compose up -d db
success "Database started"

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
        error "Database did not become ready in time. Check the logs with: docker logs job_db"
    fi
done

# Set up database initialization script
section "Setting up database initialization script"
mkdir -p init-db
cat > init-db/02-schema-update.sh << 'EOL'
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
EOL
chmod +x init-db/02-schema-update.sh
success "Database initialization script created"

# Run migrations if needed
section "Applying migrations"
# Check if tables already exist
TABLE_EXISTS=$(docker exec job_db psql -U jobuser -d jobsdb -t -c "\dt schema_version" | grep -c "schema_version" || true)

if [ "$TABLE_EXISTS" -eq "0" ]; then
    echo "Tables don't exist yet, applying migrations"
    for migration_file in migrations/*.sql; do
        if [ -f "$migration_file" ]; then
            echo "Applying migration: $migration_file"
            docker exec -i job_db psql -U jobuser -d jobsdb < "$migration_file" || echo "Warning: Error applying $migration_file"
        fi
    done
    
    # Create schema_version entry
    docker exec job_db psql -U jobuser -d jobsdb -c "
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
    success "Migrations applied"
else
    success "Database already migrated"
fi

# Start Redis first for Superset dependency
section "Starting Redis"
docker-compose up -d redis
success "Redis started"

# Start pgAdmin
section "Starting PgAdmin"
docker-compose up -d pgadmin
success "PgAdmin started"

# Build and start Superset
section "Building and starting Superset"
if ! docker-compose up -d --build superset; then
    warning "Failed to start Superset. Check the logs with: docker logs job_superset"
else
    success "Superset is starting"
fi

# Start the Job Scraper application if Dockerfile exists
if [ -f "Dockerfile" ]; then
    section "Building and starting Job Scraper"
    if ! docker-compose up -d --build scraper; then
        warning "Failed to start Job Scraper. Check the logs with: docker logs job_scraper"
    else
        success "Job Scraper started"
    fi
else
    warning "Dockerfile not found. Skipping Job Scraper service."
fi

# Show all running containers
section "Container Status"
docker-compose ps

section "Setup Complete"
echo "The job_scraper system has been set up with all components."
echo ""
echo "Services:"
echo "- Job Scraper API: http://localhost:8081"
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