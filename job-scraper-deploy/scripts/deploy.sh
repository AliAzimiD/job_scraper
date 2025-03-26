#!/bin/bash
# Job Scraper Deployment Script

# Set terminal colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color

# Logging function
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Configuration
SERVER_HOST="23.88.125.23"
SERVER_USER="root"
REMOTE_DIR="/opt/jobscraper"
DOMAIN="upgrade4u.online"
EMAIL="aliazimidarmian@gmail.com"

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run as root"
        exit 1
    fi
}

# Create directories on server
create_directories() {
    log "Creating necessary directories on the server..."
    ssh ${SERVER_USER}@${SERVER_HOST} "mkdir -p ${REMOTE_DIR}/{app,nginx,data/logs,data/static,data/certbot/conf,data/certbot/www}"
}

# Upload files to server
upload_files() {
    log "Uploading files to server..."
    # Create a tar archive of all files
    tar -czf deploy.tar.gz -C job-scraper-deploy .

    # Upload and extract
    scp deploy.tar.gz ${SERVER_USER}@${SERVER_HOST}:${REMOTE_DIR}/
    ssh ${SERVER_USER}@${SERVER_HOST} "cd ${REMOTE_DIR} && tar -xzf deploy.tar.gz && rm deploy.tar.gz"

    # Clean up local tar
    rm deploy.tar.gz
}

# Install Docker and Docker Compose on the server
install_docker() {
    log "Installing Docker and Docker Compose on server if not already installed..."
    ssh ${SERVER_USER}@${SERVER_HOST} "
        # Check if Docker is installed
        if ! command -v docker &> /dev/null; then
            echo \"Installing Docker...\"
            curl -fsSL https://get.docker.com -o get-docker.sh
            sh get-docker.sh
            rm get-docker.sh
        else
            echo \"Docker is already installed\"
        fi

        # Check if Docker Compose is installed
        if ! command -v docker-compose &> /dev/null; then
            echo \"Installing Docker Compose...\"
            curl -L \"https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)\" -o /usr/local/bin/docker-compose
            chmod +x /usr/local/bin/docker-compose
        else
            echo \"Docker Compose is already installed\"
        fi
    "
}

# Deploy the application using Docker Compose
deploy_app() {
    log "Deploying application with Docker Compose..."
    # Stop Nginx if running
    ssh ${SERVER_USER}@${SERVER_HOST} "systemctl stop nginx || true"

    # Deploy with Docker Compose
    ssh ${SERVER_USER}@${SERVER_HOST} "cd ${REMOTE_DIR} && docker-compose down -v && docker-compose up -d"
}

# Configure SSL certificates
configure_ssl() {
    log "Configuring SSL certificates..."
    ssh ${SERVER_USER}@${SERVER_HOST} "
        cd ${REMOTE_DIR}

        # Create Certbot command for SSL certificate
        docker run --rm \\
            -v ./data/certbot/conf:/etc/letsencrypt \\
            -v ./data/certbot/www:/var/www/certbot \\
            certbot/certbot \\
            certonly --webroot \\
            --webroot-path=/var/www/certbot \\
            --email ${EMAIL} \\
            --agree-tos \\
            --no-eff-email \\
            -d ${DOMAIN} \\
            || echo \"SSL certificate generation failed, please check if the domain is correctly pointed to this server\"

        # Check if certificate was successfully obtained
        if [ -d \"./data/certbot/conf/live/${DOMAIN}\" ]; then
            # Replace default Nginx config with SSL-enabled config
            cp nginx/conf/ssl.conf.template nginx/conf/default.conf
            
            # Reload Nginx to apply SSL configuration
            docker-compose exec nginx nginx -s reload
        fi
    "
}

# Display deployment status
show_status() {
    log "Checking deployment status..."
    ssh ${SERVER_USER}@${SERVER_HOST} "cd ${REMOTE_DIR} && docker-compose ps"
}

# Main function
main() {
    log "Starting deployment process..."
    
    # On local machine
    # check_root
    create_directories
    upload_files
    
    # On server
    install_docker
    deploy_app
    configure_ssl
    show_status

    log "Deployment completed successfully!"
    log "Application is now available at: http://${DOMAIN}"
    log "After SSL setup, it will be available at: https://${DOMAIN}"
}

# Run the main function
main
