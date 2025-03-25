#!/bin/bash
#
# Job Scraper Production Deployment Script for Ubuntu VPS
# This script will set up a complete production environment for running the job scraper application.
#

# Exit on error
set -e

# Colors for terminal output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Log function
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $1${NC}" >&2
    exit 1
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root or with sudo"
fi

# Installation directory
INSTALL_DIR="/opt/job-scraper"
DATA_DIR="/var/lib/job-scraper"
LOGS_DIR="/var/log/job-scraper"
BACKUP_DIR="/var/backups/job-scraper"

# Git repository URL
REPO_URL="https://github.com/yourusername/job-scraper.git"

# Default configuration
POSTGRES_DB="jobsdb"
POSTGRES_USER="jobuser"
POSTGRES_PASSWORD=$(openssl rand -base64 16)
POSTGRES_PORT="5432"
API_USERNAME="api_user"
API_PASSWORD=$(openssl rand -base64 16)
FLASK_SECRET_KEY=$(openssl rand -base64 32)
SUPERSET_SECRET_KEY=$(openssl rand -base64 32)

# Set timezone
log "Setting timezone to UTC"
timedatectl set-timezone UTC

# Update system and install basic dependencies
log "Updating system packages"
apt-get update
apt-get upgrade -y

log "Installing basic dependencies"
apt-get install -y \
    git \
    curl \
    wget \
    apt-transport-https \
    ca-certificates \
    gnupg \
    lsb-release \
    python3 \
    python3-pip \
    python3-venv \
    nginx \
    certbot \
    python3-certbot-nginx \
    cron \
    postgresql \
    postgresql-contrib \
    build-essential \
    libpq-dev

# Install Docker and Docker Compose
log "Installing Docker"
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker ubuntu
    systemctl enable docker
    systemctl start docker
    rm get-docker.sh
fi

log "Installing Docker Compose"
if ! command -v docker-compose &> /dev/null; then
    curl -L "https://github.com/docker/compose/releases/download/v2.20.3/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
fi

# Create necessary directories
log "Creating application directories"
mkdir -p $INSTALL_DIR
mkdir -p $DATA_DIR/job_data
mkdir -p $DATA_DIR/uploads
mkdir -p $LOGS_DIR
mkdir -p $BACKUP_DIR
mkdir -p $DATA_DIR/secrets

# Clone the application repository
log "Cloning the application repository"
if [ -d "$INSTALL_DIR/.git" ]; then
    log "Repository already exists, pulling latest changes"
    cd $INSTALL_DIR
    git pull
else
    # Clone repository (replace with your actual repo)
    log "Cloning fresh repository"
    git clone $REPO_URL $INSTALL_DIR
    cd $INSTALL_DIR
fi

# Create .env file with secure credentials
log "Creating .env file with secure credentials"
cat > $INSTALL_DIR/.env << EOF
# Database Configuration
POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_HOST=db
POSTGRES_PORT=$POSTGRES_PORT

# API Authentication
API_USERNAME=$API_USERNAME
API_PASSWORD=$API_PASSWORD

# Flask Configuration
FLASK_ENV=production
FLASK_DEBUG=0
FLASK_SECRET_KEY=$FLASK_SECRET_KEY

# Logging
LOG_LEVEL=INFO
LOG_DIR=$LOGS_DIR

# Superset
SUPERSET_SECRET_KEY=$SUPERSET_SECRET_KEY

# Paths
DATA_DIR=$DATA_DIR
BACKUP_DIR=$BACKUP_DIR
CONFIG_PATH=$INSTALL_DIR/config/app_config.yaml
EOF

# Setup PostgreSQL for local development
log "Setting up PostgreSQL database"
if id -u postgres &>/dev/null; then
    # PostgreSQL is installed, set up the database
    su - postgres -c "psql -c \"CREATE USER $POSTGRES_USER WITH PASSWORD '$POSTGRES_PASSWORD';\""
    su - postgres -c "psql -c \"CREATE DATABASE $POSTGRES_DB OWNER $POSTGRES_USER;\""
    su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE $POSTGRES_DB TO $POSTGRES_USER;\""
    
    # Configure PostgreSQL to allow connections from Docker
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /etc/postgresql/*/main/postgresql.conf
    echo "host    all             all             172.0.0.0/8            md5" >> /etc/postgresql/*/main/pg_hba.conf
    systemctl restart postgresql
else
    log "PostgreSQL not found - will use Docker container"
fi

# Update Docker Compose configuration to use persistent volumes
log "Updating Docker Compose configuration"
sed -i "s|job_data:/app/data|$DATA_DIR/job_data:/app/data|g" $INSTALL_DIR/docker-compose.yml
sed -i "s|postgres_data:/var/lib/postgresql/data|$DATA_DIR/postgres_data:/var/lib/postgresql/data|g" $INSTALL_DIR/docker-compose.yml
sed -i "s|superset_home:/app/superset_home|$DATA_DIR/superset_home:/app/superset_home|g" $INSTALL_DIR/docker-compose.yml
sed -i "s|redis_data:/data|$DATA_DIR/redis_data:/data|g" $INSTALL_DIR/docker-compose.yml

# Create systemd service for job scraper
log "Creating systemd service for job scraper"
cat > /etc/systemd/system/job-scraper.service << EOF
[Unit]
Description=Job Scraper Docker Compose
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_DIR
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

# Create a systemd timer to run the scraper every hour between 6 AM and 11 PM
log "Creating systemd timer for scraper execution"
cat > /etc/systemd/system/job-scraper-run.service << EOF
[Unit]
Description=Run Job Scraper
After=job-scraper.service

[Service]
Type=oneshot
User=root
WorkingDirectory=$INSTALL_DIR
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
ExecStart=/usr/bin/docker exec job-scraper-web python -m src.main

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/job-scraper-run.timer << EOF
[Unit]
Description=Run job scraper hourly between 6 AM and 11 PM
After=job-scraper.service

[Timer]
# Run hourly from 6 AM to 11 PM
OnCalendar=*-*-* 06..23:00:00
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Create backup timer
log "Creating backup timer"
cat > /etc/systemd/system/job-scraper-backup.service << EOF
[Unit]
Description=Backup Job Scraper Database
After=job-scraper.service

[Service]
Type=oneshot
User=root
WorkingDirectory=$INSTALL_DIR
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
ExecStart=/usr/bin/docker exec job-scraper-web bash /app/backup_current_db.sh

[Install]
WantedBy=multi-user.target
EOF

cat > /etc/systemd/system/job-scraper-backup.timer << EOF
[Unit]
Description=Backup job scraper database daily
After=job-scraper.service

[Timer]
OnCalendar=*-*-* 05:00:00
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
EOF

# Create log rotation configuration
log "Setting up log rotation"
cat > /etc/logrotate.d/job-scraper << EOF
$LOGS_DIR/*.log {
    daily
    missingok
    rotate 14
    compress
    delaycompress
    notifempty
    create 0640 root root
    sharedscripts
    postrotate
        systemctl reload job-scraper.service >/dev/null 2>&1 || true
    endscript
}
EOF

# Set correct permissions
log "Setting correct permissions"
chown -R ubuntu:ubuntu $INSTALL_DIR
chown -R ubuntu:ubuntu $DATA_DIR
chown -R ubuntu:ubuntu $LOGS_DIR
chown -R ubuntu:ubuntu $BACKUP_DIR

# Start and enable services
log "Enabling and starting services"
systemctl daemon-reload
systemctl enable job-scraper.service
systemctl enable job-scraper-run.timer
systemctl enable job-scraper-backup.timer
systemctl start job-scraper.service
systemctl start job-scraper-run.timer
systemctl start job-scraper-backup.timer

# Set up Nginx as a reverse proxy
log "Setting up Nginx reverse proxy"
cat > /etc/nginx/sites-available/job-scraper << EOF
server {
    listen 80;
    server_name _;

    location / {
        proxy_pass http://localhost:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /superset/ {
        proxy_pass http://localhost:8088/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /static/ {
        alias $INSTALL_DIR/static/;
        expires 1d;
    }
}
EOF

ln -sf /etc/nginx/sites-available/job-scraper /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
systemctl restart nginx

log "Installation complete!"
echo -e "${GREEN}=====================================${NC}"
echo -e "${GREEN}   Job Scraper Installation Complete   ${NC}"
echo -e "${GREEN}=====================================${NC}"
echo
echo -e "${YELLOW}Web interface: http://YOUR_SERVER_IP${NC}"
echo -e "${YELLOW}Superset analytics: http://YOUR_SERVER_IP/superset${NC}"
echo
echo -e "${YELLOW}API credentials:${NC}"
echo -e "Username: $API_USERNAME"
echo -e "Password: $API_PASSWORD"
echo
echo -e "${YELLOW}To secure your installation with HTTPS, run:${NC}"
echo "certbot --nginx -d yourdomain.com -d www.yourdomain.com"
echo
echo -e "${GREEN}=====================================${NC}" 