#!/bin/bash

# Colors for better readability
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}====== Job Scraper Development Environment ======${NC}"

# Check if Docker is running
if ! docker info > /dev/null 2>&1; then
    echo -e "${YELLOW}Docker is not running. Please start Docker and try again.${NC}"
    exit 1
fi

# Function to cleanup on exit
function cleanup {
    echo -e "\n${YELLOW}Cleaning up and stopping containers...${NC}"
    docker-compose -f docker-compose.dev.yml down
}

# Register the cleanup function to be called on exit
trap cleanup EXIT INT TERM

# Try to resolve DNS issues - use local image if available
echo -e "${YELLOW}Checking for DNS issues and using local images where possible...${NC}"

# Check if images are already available locally
PYTHON_IMAGE_EXISTS=$(docker images python:3.10.12-slim -q)
POSTGRES_IMAGE_EXISTS=$(docker images postgres:15-alpine -q)
PGADMIN_IMAGE_EXISTS=$(docker images dpage/pgadmin4 -q)

if [ -n "$PYTHON_IMAGE_EXISTS" ]; then
    echo -e "${GREEN}Python image already exists locally, skipping pull.${NC}"
else
    # Try configuring alternative DNS for Docker
    echo -e "${YELLOW}Attempting to configure alternative DNS for Docker...${NC}"
    
    # Create a dummy test container with alternative DNS
    echo -e "${YELLOW}Testing Docker connectivity with alternative DNS...${NC}"
    if docker run --rm --dns=1.1.1.1 --dns=8.8.4.4 alpine:latest ping -c 2 google.com > /dev/null 2>&1; then
        echo -e "${GREEN}Alternative DNS configuration works!${NC}"
        DNS_OPTION="--dns=1.1.1.1 --dns=8.8.4.4"
    else
        echo -e "${YELLOW}Alternative DNS failed, continuing with default configuration.${NC}"
        DNS_OPTION=""
    fi
    
    # Try to pull the image with the configured DNS
    echo -e "${YELLOW}Pulling Python image with DNS config: $DNS_OPTION${NC}"
    MAX_RETRIES=3
    RETRY_COUNT=0
    PULL_SUCCESS=false
    
    while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$PULL_SUCCESS" != "true" ]; do
        if docker pull $DNS_OPTION python:3.10.12-slim; then
            PULL_SUCCESS=true
            echo -e "${GREEN}Successfully pulled Python image.${NC}"
        else
            RETRY_COUNT=$((RETRY_COUNT + 1))
            if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
                echo -e "${YELLOW}Failed to pull image, retrying ($RETRY_COUNT/$MAX_RETRIES)...${NC}"
                sleep 10
            else
                echo -e "${RED}Failed to pull Docker image after $MAX_RETRIES attempts.${NC}"
                echo -e "${YELLOW}Will attempt to use locally cached images or build from scratch.${NC}"
            fi
        fi
    done
fi

# Check if Docker is running in WSL
if grep -q WSL /proc/version; then
    echo -e "${YELLOW}Running in WSL environment. Setting special configuration...${NC}"
    # WSL may have DNS resolution issues, especially on older versions
    if ! grep -q "nameserver 8.8.8.8" /etc/resolv.conf; then
        echo -e "${YELLOW}Adding Google DNS to /etc/resolv.conf may help with DNS issues.${NC}"
        echo -e "${YELLOW}Consider adding 'nameserver 8.8.8.8' to /etc/resolv.conf manually.${NC}"
    fi
fi

# Create secrets directory if it doesn't exist
if [ ! -d "./secrets" ]; then
    echo -e "${YELLOW}Creating secrets directory...${NC}"
    mkdir -p ./secrets
fi

# Create test config directory if it doesn't exist
if [ ! -d "./config" ]; then
    echo -e "${YELLOW}Creating config directory...${NC}"
    mkdir -p ./config
fi

# Create backups directory if it doesn't exist
if [ ! -d "./backups" ]; then
    echo -e "${YELLOW}Creating backups directory...${NC}"
    mkdir -p ./backups
fi

# Create uploads directory if it doesn't exist
if [ ! -d "./uploads" ]; then
    echo -e "${YELLOW}Creating uploads directory...${NC}"
    mkdir -p ./uploads
fi

# Create sample API config if it doesn't exist
if [ ! -f "./config/api_config.yaml" ]; then
    echo -e "${YELLOW}Creating sample API config...${NC}"
    cat > ./config/api_config.yaml << EOF
api:
  base_url: "https://example-api.com/jobs"
  headers:
    Content-Type: "application/json"
    User-Agent: "Mozilla/5.0"

request:
  default_payload:
    query: ""
    filters: {}
    sort: "newest"

scraper:
  batch_size: 50
  max_concurrent_requests: 5
  timeout: 30
  sleep_time: 1
  error_sleep_time: 5
  max_retries: 3
  database:
    enabled: true
EOF
fi

# Create init-db directory and SQL initialization script if needed
if [ ! -d "./init-db" ]; then
    echo -e "${YELLOW}Creating database initialization directory...${NC}"
    mkdir -p ./init-db
    
    # Create a basic initialization script
    cat > ./init-db/01-init.sql << EOF
-- Create schema if it doesn't exist
CREATE SCHEMA IF NOT EXISTS public;

-- Function to update timestamps
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS \$\$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
\$\$ LANGUAGE plpgsql;

-- Grant privileges
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO jobuser;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO jobuser;

-- Create jobs table if it doesn't exist
CREATE TABLE IF NOT EXISTS public.jobs (
    id VARCHAR(255) PRIMARY KEY,
    title TEXT NOT NULL,
    company_name_en TEXT,
    company_name_fa TEXT,
    description TEXT,
    url TEXT,
    activation_time TIMESTAMP WITH TIME ZONE,
    expiration_time TIMESTAMP WITH TIME ZONE,
    locations JSONB,
    job_categories JSONB,
    tags JSONB,
    work_types JSONB,
    salary JSONB,
    raw_data JSONB,
    job_post_categories JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create batches table if it doesn't exist
CREATE TABLE IF NOT EXISTS public.scraper_batches (
    batch_id VARCHAR(255) PRIMARY KEY,
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE,
    job_count INTEGER DEFAULT 0,
    status VARCHAR(50) DEFAULT 'in_progress',
    error_message TEXT,
    processing_time FLOAT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create scraper_stats table if it doesn't exist
CREATE TABLE IF NOT EXISTS public.scraper_stats (
    id SERIAL PRIMARY KEY,
    run_date TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    total_pages INTEGER DEFAULT 0,
    total_jobs INTEGER DEFAULT 0,
    new_jobs INTEGER DEFAULT 0,
    updated_jobs INTEGER DEFAULT 0,
    errors INTEGER DEFAULT 0,
    duration_seconds FLOAT,
    status VARCHAR(50),
    batch_id VARCHAR(255) REFERENCES public.scraper_batches(batch_id),
    notes TEXT
);

-- Insert sample job if the table is empty
INSERT INTO public.jobs (id, title, company_name_en, description, url, activation_time)
SELECT 
    'sample-job-1', 
    'Sample Job Title', 
    'Example Company', 
    'This is a sample job description for testing purposes.', 
    'https://example.com/job/1', 
    NOW()
WHERE NOT EXISTS (SELECT 1 FROM public.jobs LIMIT 1);
EOF
fi

# Create /monitoring directory and files
if [ ! -d "./monitoring" ]; then
    echo -e "${YELLOW}Creating monitoring directory...${NC}"
    mkdir -p ./monitoring/grafana/provisioning/datasources
    mkdir -p ./monitoring/grafana/provisioning/dashboards
    
    # Create a basic Prometheus config
    cat > ./monitoring/prometheus.yml << EOF
global:
  scrape_interval: 15s

scrape_configs:
  - job_name: 'job_scraper'
    static_configs:
      - targets: ['scraper:8081']
EOF
fi

# Create test directory if it doesn't exist
if [ ! -d "./tests" ]; then
    echo -e "${YELLOW}Creating tests directory...${NC}"
    mkdir -p ./tests
    
    # Create a simple test file
    cat > ./tests/test_basic.py << EOF
def test_imports():
    """Test that important modules can be imported."""
    try:
        from src.scraper import JobScraper
        from src.db_manager import DatabaseManager
        from src.config_manager import ConfigManager
        assert True
    except ImportError as e:
        assert False, f"Import error: {e}"

def test_configuration():
    """Test that configuration can be loaded."""
    from src.config_manager import ConfigManager
    config = ConfigManager("config/api_config.yaml")
    assert config.api_config is not None
    assert config.request_config is not None
    assert config.scraper_config is not None
EOF
fi

# Create src directory if it doesn't exist
if [ ! -d "./src" ]; then
    echo -e "${YELLOW}Creating src directory...${NC}"
    mkdir -p ./src
fi

# Create Flask templates directory if it doesn't exist
if [ ! -d "./src/templates" ]; then
    echo -e "${YELLOW}Creating Flask templates directory...${NC}"
    mkdir -p ./src/templates
    
    # Create base template with minimal content
    cat > "./src/templates/base.html" << EOF
<!DOCTYPE html>
<html>
<head>
    <title>{% block title %}Job Scraper{% endblock %}</title>
    <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/bootstrap@4.6.0/dist/css/bootstrap.min.css">
</head>
<body>
    <nav class="navbar navbar-expand-lg navbar-dark bg-primary">
        <a class="navbar-brand" href="/">Job Scraper</a>
    </nav>
    <div class="container mt-4">
        {% block content %}{% endblock %}
    </div>
    <script src="https://code.jquery.com/jquery-3.5.1.slim.min.js"></script>
    <script src="https://cdn.jsdelivr.net/npm/bootstrap@4.6.0/dist/js/bootstrap.bundle.min.js"></script>
</body>
</html>
EOF

    # Create dashboard template
    cat > "./src/templates/dashboard.html" << EOF
{% extends "base.html" %}
{% block title %}Dashboard{% endblock %}
{% block content %}
<h1>Dashboard</h1>
<div class="card">
    <div class="card-body">
        <h5 class="card-title">Job Statistics</h5>
        <p>Total Jobs: {{ job_count|default(0) }}</p>
    </div>
</div>
{% endblock %}
EOF

    # Create empty templates for other pages with minimal content
    for template in export.html import.html backup.html backups.html restore.html; do
        cat > "./src/templates/$template" << EOF
{% extends "base.html" %}
{% block title %}${template%.*}{% endblock %}
{% block content %}
<h1>${template%.*}</h1>
<p>This feature is coming soon.</p>
{% endblock %}
EOF
    done
fi

# Make sure we have a basic setup.py file for pip install -e to work
if [ ! -f "./setup.py" ]; then
    echo -e "${YELLOW}Creating basic setup.py file...${NC}"
    cat > ./setup.py << EOF
from setuptools import setup, find_packages

setup(
    name="job_scraper",
    version="0.1.0",
    packages=find_packages(),
    install_requires=[
        "aiohttp",
        "asyncio",
        "asyncpg",
        "aiofiles",
        "numpy",
        "pandas",
        "pyyaml",
        "psycopg2-binary",
        "sqlalchemy",
        "tenacity",
        "pyarrow",
        "fastparquet",
        "flask",
        "flask-bootstrap",
        "werkzeug",
        "gunicorn",
        "prometheus-client",
        "boto3",
        "python-dateutil",
        "tqdm",
    ],
)
EOF
fi

# Build and start containers
echo -e "${GREEN}Building and starting containers...${NC}"

# Check if environment variable for offline mode is set
if [ "${OFFLINE_MODE}" == "true" ]; then
    echo -e "${YELLOW}Running in OFFLINE mode. Will use local builds only.${NC}"
    USE_LOCAL_ONLY=true
else
    USE_LOCAL_ONLY=false
    
    # Check DNS resolution 
    echo -e "${YELLOW}Testing Docker DNS resolution...${NC}"
    if ! docker run $DNS_OPTION --rm alpine:latest ping -c 1 -W 5 google.com > /dev/null 2>&1; then
        echo -e "${RED}Warning: Docker container DNS resolution seems to be failing.${NC}"
        echo -e "${YELLOW}This may cause image pull failures. Switching to offline mode.${NC}"
        USE_LOCAL_ONLY=true
    fi
fi

# Start only the database first to ensure it's initialized properly
echo -e "${YELLOW}Starting database container first...${NC}"
if [ "$USE_LOCAL_ONLY" == "true" ]; then
    # Use build-only option to avoid pulling
    docker-compose -f docker-compose.dev.yml build db
    docker-compose -f docker-compose.dev.yml up -d db
else
    docker-compose -f docker-compose.dev.yml up -d --build db
fi

# Wait for the database to be healthy
echo -e "${YELLOW}Waiting for database to be healthy...${NC}"
RETRY_COUNT=0
MAX_RETRIES=30
DB_HEALTHY=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ] && [ "$DB_HEALTHY" != "true" ]; do
    if docker-compose -f docker-compose.dev.yml ps | grep db | grep "(healthy)" > /dev/null; then
        DB_HEALTHY=true
        echo -e "${GREEN}Database is healthy.${NC}"
    else
        echo -n "."
        RETRY_COUNT=$((RETRY_COUNT + 1))
        sleep 2
    fi
done

if [ "$DB_HEALTHY" != "true" ]; then
    echo -e "\n${RED}Database failed to become healthy after $MAX_RETRIES attempts.${NC}"
    echo -e "${YELLOW}Starting other containers anyway...${NC}"
fi

# Start the rest of the containers
echo -e "${YELLOW}Starting remaining containers...${NC}"
if [ "$USE_LOCAL_ONLY" == "true" ]; then
    # Use build-only option to avoid pulling
    docker-compose -f docker-compose.dev.yml build web scraper pgadmin
    docker-compose -f docker-compose.dev.yml up -d web scraper pgadmin
else
    docker-compose -f docker-compose.dev.yml up -d --build
fi

echo -e "${GREEN}Containers are starting...${NC}"
sleep 10

# Check if services are running
echo -e "${BLUE}Checking services:${NC}"
if docker ps | grep -q job_scraper_dev; then
    echo -e "${GREEN}✓ Scraper container is running${NC}"
else
    echo -e "${YELLOW}✗ Scraper container failed to start${NC}"
fi

if docker ps | grep -q job_web_dev; then
    echo -e "${GREEN}✓ Web interface container is running${NC}"
else
    echo -e "${YELLOW}✗ Web interface container failed to start${NC}"
fi

if docker ps | grep -q job_db_dev; then
    echo -e "${GREEN}✓ Database container is running${NC}"
else
    echo -e "${YELLOW}✗ Database container failed to start${NC}"
fi

if docker ps | grep -q job_pgadmin_dev; then
    echo -e "${GREEN}✓ PGAdmin container is running${NC}"
else
    echo -e "${YELLOW}✗ PGAdmin container failed to start${NC}"
fi

# Display access information
echo -e "\n${BLUE}======= Access Information ========${NC}"
echo -e "${GREEN}Web Interface:${NC} http://localhost:5000"
echo -e "${GREEN}Health Check:${NC} http://localhost:8081/health"
echo -e "${GREEN}PGAdmin:${NC} http://localhost:5050"
echo -e "  - Email: admin@example.com"
echo -e "  - Password: devpassword"
echo -e "${GREEN}Database connection for local tools:${NC}"
echo -e "  - Host: localhost"
echo -e "  - Port: 5432"
echo -e "  - Database: jobsdb"
echo -e "  - Username: jobuser"
echo -e "  - Password: devpassword"

# Attach to logs
echo -e "\n${BLUE}======= Container Logs ========${NC}"
echo -e "${YELLOW}Press Ctrl+C to exit${NC}\n"
docker-compose -f docker-compose.dev.yml logs -f 