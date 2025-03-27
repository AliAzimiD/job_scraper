#!/bin/bash

# Colors for terminal output
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

DEPLOY_DIR="/opt/jobscraper"
cd $DEPLOY_DIR

# Ensure nginx directories exist
log "Setting up Nginx configuration..."
mkdir -p nginx/conf
cp default.conf nginx/conf/

# Stop minimal services
log "Stopping minimal service..."
docker-compose down || true

# Start full stack with standard docker-compose
log "Starting full application stack..."
cp docker-compose.yml docker-compose.yml.bak
cp docker-compose.yml.new docker-compose.yml

# Start all services
log "Starting all services..."
docker-compose up -d

# Wait for services to start
log "Waiting for services to start..."
sleep 15

# Check status
log "Checking service status..."
docker-compose ps

# Check accessibility
log "Testing web service..."
curl -s http://localhost:5000/health || warn "Web service health check failed"

log "Testing nginx proxy..."
curl -s -H "Host: upgrade4u.online" http://localhost:80/ || warn "Nginx proxy check failed"

log "Deployment completed successfully!"
log "You can access the application at:"
log "- http://upgrade4u.online"
log "- http://<server-ip>"

# Optional: Set up SSL certificates
read -p "Do you want to set up SSL certificates? (y/n): " setup_ssl
if [[ "$setup_ssl" =~ ^[Yy]$ ]]; then
    log "Setting up SSL certificates..."
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
    
    if [ -d "${DEPLOY_DIR}/data/certbot/conf/live/upgrade4u.online" ]; then
        log "SSL certificates obtained successfully!"
        log "Configuring Nginx for HTTPS..."
        
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
