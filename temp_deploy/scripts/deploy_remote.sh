#!/bin/bash
# Job Scraper Application Deployment Script

# Exit on error, but with diagnostics
set -e

# Colors for terminal output
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $(date +"%Y-%m-%d %H:%M:%S") - $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $(date +"%Y-%m-%d %H:%M:%S") - $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $(date +"%Y-%m-%d %H:%M:%S") - $1"
}

# Function to handle errors
handle_error() {
    error "An error occurred at line $1"
    error "Command that failed: $(sed -n "${1}p" $0 || echo 'Unknown command')"
    
    # Display diagnostics
    if command -v docker &>/dev/null; then
        log "Current Docker containers:"
        docker ps -a
        
        # Check container logs if possible
        for container in web nginx postgres redis; do
            if docker ps -q -f name=job-scraper-$container &>/dev/null; then
                log "Logs for $container container:"
                docker logs --tail 20 job-scraper-$container
            fi
        done
    fi
    
    error "Deployment failed. Please check the logs above for details."
    exit 1
}

# Set error trap
trap 'handle_error $LINENO' ERR

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root"
    exit 1
fi

# Configuration
DOMAIN="upgrade4u.online"
EMAIL="aliazimidarmian@gmail.com"
DEPLOY_DIR="/opt/jobscraper"
NGINX_CONF_DIR="${DEPLOY_DIR}/nginx/conf"
APP_DIR="${DEPLOY_DIR}/app"
DATA_DIR="${DEPLOY_DIR}/data"
CERTBOT_DIR="${DATA_DIR}/certbot"
LOG_DIR="${DATA_DIR}/logs"
STATIC_DIR="${DATA_DIR}/static"
UPLOADS_DIR="${DATA_DIR}/uploads"
LOG_FILE="${LOG_DIR}/deployment_$(date +%Y%m%d_%H%M%S).log"

# Start logging
mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

log "Starting deployment of Job Scraper application..."

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    log "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
else
    log "Docker is already installed."
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &> /dev/null; then
    log "Installing Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
else
    log "Docker Compose is already installed."
fi

# Verify file structure
log "Verifying directory structure..."
for dir in "$NGINX_CONF_DIR" "$APP_DIR" "$CERTBOT_DIR/conf" "$CERTBOT_DIR/www" "$STATIC_DIR" "$UPLOADS_DIR"; do
    if [ ! -d "$dir" ]; then
        log "Creating directory: $dir"
        mkdir -p "$dir"
    fi
done

# Check for required files
log "Checking for required files..."
REQUIRED_FILES=(
    "${DEPLOY_DIR}/docker-compose.yml"
    "${NGINX_CONF_DIR}/default.conf"
    "${APP_DIR}/wsgi.py"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ ! -f "$file" ]; then
        error "Required file not found: $file"
        exit 1
    fi
done

# Check port availability
log "Checking for port conflicts..."
./scripts/check_port_conflicts.sh || {
    warn "Port conflict check failed but continuing as requested"
}

# Generate SSL parameters
log "Setting up SSL parameters..."
./scripts/generate_ssl_params.sh || {
    warn "SSL parameter generation failed but continuing anyway"
}

# Stop system Nginx if running
if systemctl is-active --quiet nginx; then
    log "Stopping system Nginx..."
    systemctl stop nginx
fi

# Start Docker services with error handling
log "Starting Docker services..."
cd ${DEPLOY_DIR}

# Stop any existing containers
log "Stopping existing containers..."
docker-compose down -v || warn "Failed to stop existing containers, continuing anyway"

# Pull images first
log "Pulling Docker images..."
docker-compose pull || warn "Failed to pull some Docker images, continuing anyway"

# Start services
log "Starting services..."
docker-compose up -d || {
    error "Failed to start Docker services"
    
    # Detailed diagnostics
    log "Docker Compose configuration:"
    cat docker-compose.yml
    
    log "Docker status:"
    docker info
    
    log "System memory status:"
    free -m
    
    log "Disk space:"
    df -h
    
    exit 1
}

# Wait for services to start
log "Waiting for services to start up..."
sleep 15

# Check service health
log "Checking service health..."
for service in web postgres redis nginx; do
    if ! docker ps | grep -q job-scraper-$service; then
        warn "Service $service is not running"
        docker logs job-scraper-$service
    fi
done

# Set up SSL certificates
log "Setting up SSL certificates..."

# Create SSL certificate
docker run --rm \
    -v ${CERTBOT_DIR}/conf:/etc/letsencrypt \
    -v ${CERTBOT_DIR}/www:/var/www/certbot \
    certbot/certbot \
    certonly --webroot \
    --webroot-path=/var/www/certbot \
    --email ${EMAIL} \
    --agree-tos \
    --no-eff-email \
    -d ${DOMAIN} \
    || warn "Failed to obtain SSL certificate. The site will still work over HTTP."

# If certificate was obtained, update Nginx config
if [ -d "${CERTBOT_DIR}/conf/live/${DOMAIN}" ]; then
    log "SSL certificate obtained successfully. Updating Nginx configuration..."
    cp ${NGINX_CONF_DIR}/ssl.conf.template ${NGINX_CONF_DIR}/default.conf
    docker-compose exec -T nginx nginx -s reload
    log "Nginx configuration updated. The site is now available over HTTPS."
else
    warn "No SSL certificate found. The site will only be available over HTTP."
fi

# Run diagnostic checks
log "Running diagnostic checks..."

# Check if web service is responding
if curl -s http://localhost:5000/health | grep -q "healthy"; then
    log "Web service is healthy."
else
    warn "Web service health check failed."
    docker logs job-scraper-web
fi

# Check if Nginx is responding
if curl -s http://localhost | grep -q "Job Scraper"; then
    log "Nginx is proxying correctly to the application."
else
    warn "Nginx proxy check failed."
    docker logs job-scraper-nginx
fi

log "Deployment completed successfully!"
log "Application is now available at: http://${DOMAIN}"
if [ -d "${CERTBOT_DIR}/conf/live/${DOMAIN}" ]; then
    log "You can also access it securely at: https://${DOMAIN}"
fi

# Show status
docker-compose ps

log "For more details, check the logs in: ${LOG_FILE}" 