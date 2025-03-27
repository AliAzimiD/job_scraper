#!/bin/bash
# Quick script to fix the Job Scraper deployment issues

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

# Check for dependencies
log "Checking for required dependencies..."
for cmd in ssh scp tar; do
    if ! command -v $cmd &> /dev/null; then
        error "$cmd is not installed. Please install it and try again."
        exit 1
    fi
done

# Create fix directory
log "Creating fix directory..."
mkdir -p fix_deploy

# Create proper wsgi.py
log "Creating wsgi.py..."
cat > fix_deploy/wsgi.py << 'EOF'
"""
WSGI entry point for the Job Scraper application.
This file is used by Gunicorn to serve the application.
"""
import os
from app import create_app

# Create the Flask application instance
app = create_app()

if __name__ == "__main__":
    # Run the app only if this file is executed directly
    port = int(os.environ.get("PORT", 5000))
    app.run(host="0.0.0.0", port=port)
EOF

# Create fixed Dockerfile
log "Creating fixed Dockerfile..."
cat > fix_deploy/Dockerfile << 'EOF'
FROM python:3.11-slim

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PYTHONFAULTHANDLER=1

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    postgresql-client \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Create necessary directories with appropriate permissions
RUN mkdir -p /app/logs /app/static /app/uploads /app/data \
    && chmod -R 755 /app

# Copy requirements first for better caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Add health check
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:5000/health || exit 1

# Expose port
EXPOSE 5000

# Set entry point
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "3", "--timeout", "60", "--access-logfile", "/app/logs/gunicorn_access.log", "--error-logfile", "/app/logs/gunicorn_error.log", "wsgi:app"]
EOF

# Create fixed docker-compose.yml with environment variables 
log "Creating fixed docker-compose.yml..."
cat > fix_deploy/docker-compose.yml << 'EOF'
version: "3.8"

services:
  web:
    build:
      context: ./app
    container_name: job-scraper-web
    restart: unless-stopped
    volumes:
      - ./app:/app
      - ./data/logs:/app/logs
      - ./data/static:/app/static
      - ./data/uploads:/app/uploads
    environment:
      - FLASK_APP=app
      - FLASK_ENV=production
      - FLASK_DEBUG=0
      - DATABASE_URL=postgresql://${POSTGRES_USER:-postgres}:${POSTGRES_PASSWORD:-aliazimid}@postgres:5432/${POSTGRES_DB:-jobsdb}
      - REDIS_HOST=redis
      - REDIS_PORT=6379
      - SECRET_KEY=${SECRET_KEY:-$(openssl rand -hex 32)}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:5000/health"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks:
      - job-scraper-network
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  postgres:
    image: postgres:15-alpine
    container_name: job-scraper-postgres
    restart: unless-stopped
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./data/init-db:/docker-entrypoint-initdb.d
    environment:
      - POSTGRES_USER=${POSTGRES_USER:-postgres}
      - POSTGRES_PASSWORD=${POSTGRES_PASSWORD:-aliazimid}
      - POSTGRES_DB=${POSTGRES_DB:-jobsdb}
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${POSTGRES_USER:-postgres}"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s
    networks:
      - job-scraper-network
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  redis:
    image: redis:7-alpine
    container_name: job-scraper-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - job-scraper-network
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  nginx:
    image: nginx:1.25-alpine
    container_name: job-scraper-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf:/etc/nginx/conf.d
      - ./data/static:/usr/share/nginx/html/static
      - ./data/certbot/conf:/etc/letsencrypt
      - ./data/certbot/www:/var/www/certbot
    healthcheck:
      test: ["CMD", "nginx", "-t"]
      interval: 30s
      timeout: 10s
      retries: 3
    depends_on:
      web:
        condition: service_healthy
    networks:
      - job-scraper-network
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"

  certbot:
    image: certbot/certbot
    container_name: job-scraper-certbot
    volumes:
      - ./data/certbot/conf:/etc/letsencrypt
      - ./data/certbot/www:/var/www/certbot
    entrypoint: "/bin/sh -c \"trap exit TERM; while :; do certbot renew; sleep 12h & wait $${!}; done;\""

volumes:
  postgres-data:
  redis-data:

networks:
  job-scraper-network:
    driver: bridge
EOF

# Create SSL parameters script
log "Creating SSL parameters script..."
cat > fix_deploy/generate_ssl_params.sh << 'EOF'
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
    cat > "$OPTIONS_FILE" << 'EOFINNER'
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
EOFINNER
    log "SSL options file created successfully."
else
    log "SSL options file already exists."
fi

# Set proper permissions
chmod 644 "$DHPARAM_FILE" "$OPTIONS_FILE"

log "SSL parameters setup completed successfully."
EOF

# Create package and upload
log "Creating and uploading fix package..."
chmod +x fix_deploy/generate_ssl_params.sh
tar -czf fix.tar.gz -C fix_deploy .
scp fix.tar.gz ${SERVER_USER}@${SERVER_HOST}:${DEPLOY_DIR}/
ssh ${SERVER_USER}@${SERVER_HOST} "cd ${DEPLOY_DIR} && tar -xzf fix.tar.gz && \
    chmod +x generate_ssl_params.sh && \
    cp wsgi.py app/ && \
    cp Dockerfile app/ && \
    ./generate_ssl_params.sh && \
    docker-compose down && \
    docker-compose up -d"

# Clean up
log "Cleaning up..."
rm -rf fix_deploy fix.tar.gz

log "Fix deployment completed! Check the application at http://upgrade4u.online" 