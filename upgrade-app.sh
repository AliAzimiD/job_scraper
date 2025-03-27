#!/bin/bash
# Script to upgrade from minimal application to full application

# Set terminal colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Logging functions
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
DEPLOY_DIR="/opt/jobscraper"

# Create temporary directory
mkdir -p upgrade_app

# Create full app structure by copying the existing ones from job-scraper-deploy
log "Creating full application files..."
mkdir -p upgrade_app/app/db

# Copy files from job-scraper-deploy
cp -r job-scraper-deploy/app/* upgrade_app/app/
cp job-scraper-deploy/docker-compose.yml upgrade_app/

# Create a backup script to run on the server
cat > upgrade_app/upgrade.sh << 'EOF'
#!/bin/bash

# Set terminal colors
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color

# Logging functions
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
DEPLOY_DIR="/opt/jobscraper"
cd $DEPLOY_DIR

# Backup current working app
log "Backing up current application..."
mkdir -p backup
cp -r app backup/
cp docker-compose.yml backup/

# Stop the current containers
log "Stopping current containers..."
docker-compose down

# Update application files with full version
log "Updating application files..."
cp -r full_app/* app/

# Ensure directory structure is correct
mkdir -p data/logs data/static data/uploads

# Set correct permissions
chmod -R 755 app
chmod -R 777 data/logs data/static data/uploads

# Start with the full docker-compose configuration
log "Starting full application stack..."
docker-compose up -d

# Wait for services to start
log "Waiting for services to start..."
sleep 20

# Check status
log "Checking container status..."
docker-compose ps

# Test the application
log "Testing the application..."
curl -s http://localhost:5000/health

# Success message
log "Application upgrade completed!"
log "The application should now be accessible at:"
log "- http://upgrade4u.online"

# Ask about SSL setup
read -p "Do you want to set up SSL certificates now? (y/n): " setup_ssl
if [[ "$setup_ssl" =~ ^[Yy]$ ]]; then
    log "Setting up SSL certificates..."
    
    # Generate SSL certificates using certbot
    docker run --rm \
        -v ${DEPLOY_DIR}/data/certbot/conf:/etc/letsencrypt \
        -v ${DEPLOY_DIR}/data/certbot/www:/var/www/certbot \
        certbot/certbot \
        certonly --webroot \
        --webroot-path=/var/www/certbot \
        --email aliazimidarmian@gmail.com \
        --agree-tos \
        --no-eff-email \
        -d upgrade4u.online
    
    # Check if certificate was obtained
    if [ -d "${DEPLOY_DIR}/data/certbot/conf/live/upgrade4u.online" ]; then
        log "SSL certificate obtained successfully!"
        
        # Create SSL-enabled Nginx config
        cat > nginx/conf/default.conf << 'EOFSSL'
server {
    listen 443 ssl http2;
    server_name upgrade4u.online;

    ssl_certificate /etc/letsencrypt/live/upgrade4u.online/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/upgrade4u.online/privkey.pem;
    
    # SSL configuration
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers on;
    ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    
    # Use a custom DH param if available, otherwise skip
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;
    
    # HSTS (uncomment after confirming site works with HTTPS)
    add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;

    access_log /var/log/nginx/jobscraper_access.log;
    error_log /var/log/nginx/jobscraper_error.log;

    location / {
        proxy_pass http://web:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
        proxy_connect_timeout 120s;
    }

    location /static {
        alias /usr/share/nginx/html/static;
        expires 30d;
        add_header Cache-Control "public, max-age=2592000";
    }

    # Add security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Permissions-Policy "camera=(), geolocation=(), microphone=()";
}

server {
    listen 80;
    server_name upgrade4u.online;
    
    location / {
        return 301 https://$host$request_uri;
    }
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
}
EOFSSL
        
        # Reload Nginx
        docker-compose exec -T nginx nginx -s reload
        
        log "HTTPS has been configured successfully!"
        log "You can now access the application securely at: https://upgrade4u.online"
    else
        warn "Failed to obtain SSL certificates. The site will only be available over HTTP."
    fi
fi
EOF

# Add execute permission to the script
chmod +x upgrade_app/upgrade.sh

# Upload the files
log "Uploading application files to server..."
ssh ${SERVER_USER}@${SERVER_HOST} "mkdir -p ${DEPLOY_DIR}/full_app"
scp -r upgrade_app/app/* ${SERVER_USER}@${SERVER_HOST}:${DEPLOY_DIR}/full_app/
scp upgrade_app/upgrade.sh ${SERVER_USER}@${SERVER_HOST}:${DEPLOY_DIR}/

# Run the upgrade script on the server
log "Running upgrade script on server..."
log "You will need to enter the server password when prompted."
log "Execute the following command to upgrade the application:"
log "ssh ${SERVER_USER}@${SERVER_HOST} \"cd ${DEPLOY_DIR} && chmod +x upgrade.sh && ./upgrade.sh\""

# Clean up
log "Cleaning up temporary files..."
rm -rf upgrade_app

log "Preparation completed! Follow the instructions above to complete the upgrade." 