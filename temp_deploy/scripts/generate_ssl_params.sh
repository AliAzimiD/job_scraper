#!/bin/bash
# Script to generate SSL parameters for Nginx

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

# Set paths
CERTBOT_DIR="/opt/jobscraper/data/certbot/conf"
DHPARAM_FILE="${CERTBOT_DIR}/ssl-dhparams.pem"
OPTIONS_FILE="${CERTBOT_DIR}/options-ssl-nginx.conf"

# Create directory structure if it doesn't exist
if [ ! -d "$CERTBOT_DIR" ]; then
    log "Creating directory: $CERTBOT_DIR"
    mkdir -p "$CERTBOT_DIR"
fi

# Generate DH parameters if they don't exist
if [ ! -f "$DHPARAM_FILE" ]; then
    log "Generating DH parameters (this may take a few minutes)..."
    openssl dhparam -out "$DHPARAM_FILE" 2048
    log "DH parameters generated successfully."
else
    log "DH parameters file already exists."
fi

# Create options-ssl-nginx.conf if it doesn't exist
if [ ! -f "$OPTIONS_FILE" ]; then
    log "Creating SSL options file..."
    cat > "$OPTIONS_FILE" << EOF
# SSL options for Nginx
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers on;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384';
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;
ssl_stapling on;
ssl_stapling_verify on;
resolver 8.8.8.8 8.8.4.4 valid=300s;
resolver_timeout 5s;
add_header Strict-Transport-Security "max-age=63072000; includeSubDomains; preload" always;
add_header X-Frame-Options SAMEORIGIN always;
add_header X-Content-Type-Options nosniff always;
add_header X-XSS-Protection "1; mode=block" always;
EOF
    log "SSL options file created successfully."
else
    log "SSL options file already exists."
fi

# Set proper permissions
chmod 644 "$DHPARAM_FILE" "$OPTIONS_FILE"

log "SSL parameters setup completed successfully." 