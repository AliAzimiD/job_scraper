#!/bin/bash
# Job Scraper Application Setup Script

# Color codes for formatting
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Print section header
section() {
    echo -e "\n${GREEN}=== $1 ===${NC}\n"
}

# Print info message
info() {
    echo -e "${YELLOW}INFO:${NC} $1"
}

# Print error message
error() {
    echo -e "${RED}ERROR:${NC} $1"
}

# Print success message
success() {
    echo -e "${GREEN}SUCCESS:${NC} $1"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check prerequisites
check_prerequisites() {
    section "Checking Prerequisites"
    
    # Check Python
    if command_exists python3; then
        python_version=$(python3 --version)
        info "Found $python_version"
    else
        error "Python 3 not found. Please install Python 3.10 or higher."
        info "Note: This project uses 'python3' command. If you have Python installed but accessible through a different command (e.g., 'python'), you may need to create a symlink or alias."
        exit 1
    fi
    
    # Check pip
    if command_exists pip3; then
        pip_version=$(pip3 --version)
        info "Found pip: $pip_version"
    else
        error "pip not found. Please install pip."
        info "Note: This project expects pip to be available as 'pip3'. On some systems, you may need to install the python3-pip package."
        exit 1
    fi
    
    # Check Docker (optional)
    if command_exists docker; then
        docker_version=$(docker --version)
        info "Found $docker_version"
        
        if command_exists docker-compose; then
            compose_version=$(docker-compose --version)
            info "Found Docker Compose: $compose_version"
        else
            info "Docker Compose not found. This is optional but recommended."
        fi
    else
        info "Docker not found. This is optional but recommended for containerized deployment."
    fi
    
    success "All essential prerequisites are met."
}

# Create necessary directories
create_directories() {
    section "Creating Directories"
    
    mkdir -p static/css static/js uploads app/templates/errors
    
    if [ $? -eq 0 ]; then
        success "Directories created successfully."
    else
        error "Failed to create directories."
        exit 1
    fi
}

# Create virtual environment
create_virtualenv() {
    section "Setting up Virtual Environment"
    
    if [ -d "venv" ]; then
        info "Virtual environment already exists."
    else
        info "Creating virtual environment..."
        python3 -m venv venv
        
        if [ $? -eq 0 ]; then
            success "Virtual environment created successfully."
        else
            error "Failed to create virtual environment."
            exit 1
        fi
    fi
    
    info "Activating virtual environment..."
    source venv/bin/activate
    
    if [ $? -eq 0 ]; then
        success "Virtual environment activated."
    else
        error "Failed to activate virtual environment."
        exit 1
    fi
}

# Install dependencies
install_dependencies() {
    section "Installing Dependencies"
    
    if [ -f "requirements.txt" ]; then
        info "Installing packages from requirements.txt..."
        pip install -r requirements.txt
        
        if [ $? -eq 0 ]; then
            success "Dependencies installed successfully."
        else
            error "Failed to install dependencies."
            exit 1
        fi
    else
        info "Creating requirements.txt..."
        cat > requirements.txt << EOF
Flask==2.3.7
Flask-SQLAlchemy==3.1.1
Flask-Migrate==4.0.5
psycopg2-binary==2.9.9
redis==5.0.1
prometheus-client==0.19.0
requests==2.31.0
beautifulsoup4==4.12.2
Werkzeug==2.3.7
Jinja2==3.1.2
python-dotenv==1.0.0
gunicorn==21.2.0
pytest==7.4.3
pytest-cov==4.1.0
EOF
        
        info "Installing packages from newly created requirements.txt..."
        pip install -r requirements.txt
        
        if [ $? -eq 0 ]; then
            success "Dependencies installed successfully."
        else
            error "Failed to install dependencies."
            exit 1
        fi
    fi
}

# Configure environment
configure_environment() {
    section "Configuring Environment"
    
    if [ -f ".env" ]; then
        info ".env file already exists."
    else
        info "Creating .env file..."
        cat > .env << EOF
# Flask configuration
FLASK_APP=app
FLASK_ENV=development
FLASK_DEBUG=1
FLASK_RUN_HOST=0.0.0.0
FLASK_RUN_PORT=5001
SECRET_KEY=$(python3 -c "import secrets; print(secrets.token_hex(32))")

# Database configuration
DATABASE_URL=postgresql://postgres:postgres@localhost:5432/jobsdb

# Redis configuration
REDIS_HOST=localhost
REDIS_PORT=6379

# Application configuration
UPLOAD_FOLDER=uploads
LOG_LEVEL=INFO
EOF
        
        if [ $? -eq 0 ]; then
            success ".env file created successfully."
        else
            error "Failed to create .env file."
            exit 1
        fi
    fi
}

# Initialize database
initialize_database() {
    section "Initializing Database"
    
    info "This step requires a running PostgreSQL server."
    info "You can set up PostgreSQL manually or use Docker."
    info "Skipping automatic database initialization."
    info "Please run the following commands manually after setting up PostgreSQL:"
    echo
    echo "  flask db init"
    echo "  flask db migrate -m \"Initial migration.\""
    echo "  flask db upgrade"
    echo
}

# Set up Docker if available
setup_docker() {
    section "Docker Configuration"
    
    if command_exists docker; then
        if [ -f "docker-compose.yml" ]; then
            info "docker-compose.yml already exists."
        else
            info "Creating docker-compose.yml..."
            cat > docker-compose.yml << EOF
version: '3.8'

services:
  app:
    build: .
    container_name: job_scraper_app
    restart: always
    ports:
      - "5001:5001"
    volumes:
      - ./:/app
      - ./uploads:/app/uploads
    environment:
      - FLASK_APP=app
      - FLASK_DEBUG=1
      - DATABASE_URL=postgresql://postgres:postgres@db:5432/jobsdb
      - REDIS_HOST=redis
      - REDIS_PORT=6379
    depends_on:
      - db
      - redis

  db:
    image: postgres:15-alpine
    container_name: job_scraper_db
    restart: always
    environment:
      - POSTGRES_PASSWORD=postgres
      - POSTGRES_USER=postgres
      - POSTGRES_DB=jobsdb
    volumes:
      - postgres_data:/var/lib/postgresql/data
    ports:
      - "5432:5432"

  redis:
    image: redis:7-alpine
    container_name: job_scraper_redis
    restart: always
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data

  prometheus:
    image: prom/prometheus:latest
    container_name: job_scraper_prometheus
    restart: always
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
    ports:
      - "9090:9090"

  grafana:
    image: grafana/grafana:latest
    container_name: job_scraper_grafana
    restart: always
    ports:
      - "3000:3000"
    volumes:
      - grafana_data:/var/lib/grafana
    depends_on:
      - prometheus

volumes:
  postgres_data:
  redis_data:
  grafana_data:
EOF
            
            if [ $? -eq 0 ]; then
                success "docker-compose.yml created successfully."
            else
                error "Failed to create docker-compose.yml."
            fi
        fi
        
        if [ -f "Dockerfile" ]; then
            info "Dockerfile already exists."
        else
            info "Creating Dockerfile..."
            cat > Dockerfile << EOF
FROM python:3.10-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Create required directories
RUN mkdir -p uploads

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV FLASK_APP=app
ENV FLASK_RUN_HOST=0.0.0.0
ENV FLASK_RUN_PORT=5001

# Expose port
EXPOSE 5001

# Run the application
CMD ["flask", "run"]
EOF
            
            if [ $? -eq 0 ]; then
                success "Dockerfile created successfully."
            else
                error "Failed to create Dockerfile."
            fi
        fi
        
        if [ -f "prometheus.yml" ]; then
            info "prometheus.yml already exists."
        else
            info "Creating prometheus.yml..."
            cat > prometheus.yml << EOF
global:
  scrape_interval: 15s
  evaluation_interval: 15s

scrape_configs:
  - job_name: 'job-scraper'
    scrape_interval: 5s
    static_configs:
      - targets: ['app:5001']
EOF
            
            if [ $? -eq 0 ]; then
                success "prometheus.yml created successfully."
            else
                error "Failed to create prometheus.yml."
            fi
        fi
        
        info "Docker configuration completed."
        info "You can start the application with Docker using: docker-compose up -d"
    else
        info "Docker not found. Skipping Docker configuration."
    fi
}

# Create basic application test
create_test() {
    section "Creating Test Script"
    
    if [ -f "test_app.py" ]; then
        info "test_app.py already exists."
    else
        info "test_app.py has been created separately."
    fi
}

# Main function
main() {
    section "Job Scraper Application Setup"
    
    check_prerequisites
    create_directories
    create_virtualenv
    install_dependencies
    configure_environment
    initialize_database
    setup_docker
    create_test
    
    section "Setup Complete"
    info "The Job Scraper application has been set up successfully."
    info "To start the application in development mode, run:"
    echo
    echo "  source venv/bin/activate"
    echo "  flask run"
    echo
    info "Or with Docker:"
    echo
    echo "  docker-compose up -d"
    echo
    info "Access the application at: http://localhost:5001"
    
    success "Setup completed successfully!"
}

# Run the main function
main 