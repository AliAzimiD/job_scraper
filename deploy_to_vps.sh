#!/bin/bash
set -e

# Job Scraper Production Deployment Script
# This script deploys the Job Scraper application to a remote VPS

# Configuration - Use environment variables or prompt for credentials
VPS_IP="${VPS_IP:-23.88.125.23}"
VPS_USER="${VPS_USER:-root}"
VPS_PASSWORD="${VPS_PASSWORD:-}"  # Will prompt if not set
APP_DIR="/opt/job-scraper"
DOMAIN_NAME="${DOMAIN_NAME:-}"  # Set this if you have a domain pointed to the server
SSH_OPTS="-o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=30"

# Function to handle errors
handle_error() {
    echo "ERROR: $1"
    echo "The deployment script encountered an error. Please fix the issue and try again."
    exit 1
}

echo "===================================================="
echo "Job Scraper Production Deployment"
echo "===================================================="

# Prompt for VPS password if not set
if [ -z "$VPS_PASSWORD" ]; then
    echo -n "Enter VPS password for ${VPS_USER}@${VPS_IP}: "
    read -s VPS_PASSWORD
    echo ""
    if [ -z "$VPS_PASSWORD" ]; then
        handle_error "Password cannot be empty"
    fi
fi

# Install sshpass if not available
if ! command -v sshpass &> /dev/null; then
    echo "Installing sshpass for non-interactive SSH..."
    sudo apt-get update && sudo apt-get install -y sshpass || handle_error "Failed to install sshpass"
fi

# Function to run commands on the remote server
run_remote() {
    local max_retries=3
    local retry_count=0
    local cmd="$1"
    
    while [ $retry_count -lt $max_retries ]; do
        echo "  → Running command on remote server (attempt $((retry_count+1))/$max_retries)..."
        if sshpass -p "${VPS_PASSWORD}" ssh $SSH_OPTS ${VPS_USER}@${VPS_IP} "$cmd"; then
            return 0
        else
            echo "  → Command failed, retrying in 5 seconds..."
            retry_count=$((retry_count+1))
            sleep 5
        fi
    done
    
    echo "Error executing command on remote server after $max_retries attempts: $cmd"
    return 1
}

# Function to copy files to the remote server
copy_to_remote() {
    local max_retries=3
    local retry_count=0
    local src="$1"
    local dest="$2"
    
    while [ $retry_count -lt $max_retries ]; do
        echo "  → Copying files to remote server (attempt $((retry_count+1))/$max_retries)..."
        if sshpass -p "${VPS_PASSWORD}" rsync -avz --progress --exclude 'venv' --exclude '__pycache__' --exclude '*.pyc' "$src" ${VPS_USER}@${VPS_IP}:"$dest"; then
            return 0
        else
            echo "  → File transfer failed, retrying in 5 seconds..."
            retry_count=$((retry_count+1))
            sleep 5
        fi
    done
    
    echo "Error copying files to remote server after $max_retries attempts: $src -> $dest"
    return 1
}

echo "Setting up remote server..."

# 1. Install required packages on the remote server
echo "Installing system dependencies..."
run_remote "apt-get update && apt-get install -y python3 python3-pip python3-venv docker.io docker-compose nginx certbot python3-certbot-nginx git postgresql-client jq curl" || handle_error "Failed to install system dependencies"

# 2. Create application directory and all required subdirectories
echo "Creating application directories..."
run_remote "mkdir -p ${APP_DIR}/{prometheus/rules,grafana/provisioning/datasources,grafana/dashboards,alert_rules,backups,logs,docs/{images,dashboards,alerts}}" || handle_error "Failed to create application directories"

# 3. Copy application files to the server
echo "Copying application files to server..."
copy_to_remote "./" "${APP_DIR}" || handle_error "Failed to copy application files"

# 4. Set up Docker and Docker Compose on the remote server - CAREFUL WITH THIS COMMAND
echo "Setting up Docker..."
# Execute docker commands separately to prevent connection loss when restarting services
run_remote "if ! systemctl is-enabled docker >/dev/null 2>&1; then systemctl enable docker; fi" || handle_error "Failed to enable Docker"
run_remote "if ! systemctl is-active docker >/dev/null 2>&1; then systemctl start docker; fi" || handle_error "Failed to start Docker"
run_remote "docker --version || { echo 'Docker installation failed'; exit 1; }" || handle_error "Docker installation verification failed"

# 5. Create Docker network if it doesn't exist
echo "Creating Docker network..."
run_remote "docker network inspect job-scraper-network >/dev/null 2>&1 || docker network create job-scraper-network" || handle_error "Failed to create Docker network"

# 6. Set up environment file on the remote server
echo "Setting up environment file..."
if [ -f .env.example ]; then
    copy_to_remote ".env.example" "${APP_DIR}/.env" || handle_error "Failed to copy environment file"
    echo "Copied .env.example to server. You may need to edit it with proper credentials."
else
    echo "Creating basic .env file..."
    local_rand_key=$(openssl rand -hex 24)
    local_rand_pass=$(openssl rand -hex 16)
    run_remote "cat > ${APP_DIR}/.env << EOF
POSTGRES_USER=jobuser
POSTGRES_PASSWORD=secure_password_change_me
POSTGRES_DB=jobsdb
FLASK_SECRET_KEY=${local_rand_key}
API_USERNAME=api_user
API_PASSWORD=${local_rand_pass}
EOF" || handle_error "Failed to create environment file"
fi

# 7. Start the application and monitoring stack
echo "Starting application and monitoring stack..."
run_remote "cd ${APP_DIR} && docker-compose down --remove-orphans" || echo "No containers to remove, continuing..."
run_remote "cd ${APP_DIR} && docker-compose up -d || { echo 'Failed to start application containers'; exit 1; }" || handle_error "Failed to start application containers"
echo "Waiting for application containers to stabilize..."
sleep 15
run_remote "cd ${APP_DIR} && docker-compose -f docker-compose.monitoring.yml down --remove-orphans" || echo "No monitoring containers to remove, continuing..."
run_remote "cd ${APP_DIR} && docker-compose -f docker-compose.monitoring.yml up -d || { echo 'Failed to start monitoring containers'; exit 1; }" || handle_error "Failed to start monitoring containers"

# 8. Set up Nginx as a reverse proxy (if domain is provided)
if [ ! -z "$DOMAIN_NAME" ]; then
    echo "Setting up Nginx and SSL for domain ${DOMAIN_NAME}..."
    run_remote "cat > /etc/nginx/sites-available/job-scraper << EOF
server {
    listen 80;
    server_name ${DOMAIN_NAME};

    location / {
        proxy_pass http://localhost:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /grafana/ {
        proxy_pass http://localhost:3000/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /prometheus/ {
        proxy_pass http://localhost:9090/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF" || handle_error "Failed to create Nginx configuration"
    run_remote "ln -sf /etc/nginx/sites-available/job-scraper /etc/nginx/sites-enabled/" || handle_error "Failed to enable Nginx site"
    run_remote "nginx -t && systemctl restart nginx" || handle_error "Nginx configuration test failed"
    
    # Set up SSL with Certbot
    run_remote "certbot --nginx -d ${DOMAIN_NAME} --non-interactive --agree-tos -m admin@${DOMAIN_NAME} || echo 'SSL setup failed, you can manually set it up later'"
else
    echo "No domain provided, skipping Nginx setup"
fi

# 9. Set up a backup script for Prometheus and Grafana data
echo "Setting up backup system..."
run_remote "cat > ${APP_DIR}/backup_monitoring.sh << EOF
#!/bin/bash
BACKUP_DIR=\"${APP_DIR}/backups\"
DATE=\$(date +%Y-%m-%d)

# Create backup directory
mkdir -p \$BACKUP_DIR

# Stop containers to ensure data consistency
cd ${APP_DIR} && docker-compose -f docker-compose.monitoring.yml stop prometheus grafana

# Backup volumes
docker run --rm -v prometheus_data:/data -v \$BACKUP_DIR:/backup \\
  alpine tar -czf /backup/prometheus-\$DATE.tar.gz /data

docker run --rm -v grafana_data:/data -v \$BACKUP_DIR:/backup \\
  alpine tar -czf /backup/grafana-\$DATE.tar.gz /data

# Export Grafana dashboards
docker run --rm -v \$BACKUP_DIR:/backup \\
  --network=job-scraper-network curlimages/curl \\
  -s http://admin:admin@grafana:3000/api/dashboards > \$BACKUP_DIR/dashboards-\$DATE.json

# Restart containers
cd ${APP_DIR} && docker-compose -f docker-compose.monitoring.yml start prometheus grafana

# Rotate old backups (keep last 14 days)
find \$BACKUP_DIR -name \"prometheus-*.tar.gz\" -type f -mtime +14 -delete
find \$BACKUP_DIR -name \"grafana-*.tar.gz\" -type f -mtime +14 -delete
find \$BACKUP_DIR -name \"dashboards-*.json\" -type f -mtime +14 -delete
EOF" || handle_error "Failed to create backup script"

run_remote "chmod +x ${APP_DIR}/backup_monitoring.sh" || handle_error "Failed to make backup script executable"

# 10. Set up a cron job for regular backups
echo "Setting up backup schedule..."
run_remote "(crontab -l 2>/dev/null; echo '0 2 * * * ${APP_DIR}/backup_monitoring.sh > ${APP_DIR}/backups/backup.log 2>&1') | crontab -" || handle_error "Failed to set up backup schedule"

# 11. Create a script to check monitoring health
echo "Creating monitoring health check script..."
run_remote "cat > ${APP_DIR}/check_monitoring.sh << EOF
#!/bin/bash
PROMETHEUS_URL=\"http://localhost:9090\"
GRAFANA_URL=\"http://localhost:3000\"

echo \"Checking monitoring system health...\"

# Check Prometheus
if curl -s \$PROMETHEUS_URL/-/healthy > /dev/null; then
    echo \"✓ Prometheus is healthy\"
else
    echo \"✗ Prometheus is not responding\"
    exit 1
fi

# Check Grafana
if curl -s \$GRAFANA_URL/api/health > /dev/null; then
    echo \"✓ Grafana is healthy\"
else
    echo \"✗ Grafana is not responding\"
    exit 1
fi

# Check targets in Prometheus
TARGETS=\$(curl -s \$PROMETHEUS_URL/api/v1/targets | grep -o '\"health\":\"up\"' | wc -l)
TOTAL=\$(curl -s \$PROMETHEUS_URL/api/v1/targets | grep -o '\"health\"' | wc -l)

echo \"Targets up: \$TARGETS / \$TOTAL\"

if [ \$TARGETS -eq 0 ]; then
    echo \"✗ No targets are up in Prometheus\"
    exit 1
elif [ \$TARGETS -lt \$TOTAL ]; then
    echo \"⚠ Some targets are down in Prometheus\"
else
    echo \"✓ All targets are up in Prometheus\"
fi

echo \"Monitoring system is healthy!\"
EOF" || handle_error "Failed to create health check script"

run_remote "chmod +x ${APP_DIR}/check_monitoring.sh" || handle_error "Failed to make health check script executable"

# 12. Verify services are running
echo "Verifying services..."
echo "Waiting 30 seconds for services to fully start up..."
sleep 30
run_remote "docker ps | grep job-scraper-web || echo 'Warning: Application container not running'"
run_remote "docker ps | grep prometheus || echo 'Warning: Prometheus container not running'"
run_remote "docker ps | grep grafana || echo 'Warning: Grafana container not running'"
run_remote "cd ${APP_DIR} && ./check_monitoring.sh || echo 'Warning: Some monitoring services are not healthy yet. They may need more time to initialize.'"

echo "===================================================="
echo "Deployment Completed!"
echo "===================================================="
echo
echo "Your Job Scraper application should now be running at:"
echo "  - Web interface: http://${VPS_IP}:5000"
echo "  - Grafana: http://${VPS_IP}:3000 (login: admin/admin)"
echo "  - Prometheus: http://${VPS_IP}:9090"
echo
echo "To check the status of the services, run:"
echo "  ssh ${VPS_USER}@${VPS_IP} 'cd ${APP_DIR} && docker-compose ps'"
echo
echo "To check monitoring health, run:"
echo "  ssh ${VPS_USER}@${VPS_IP} '${APP_DIR}/check_monitoring.sh'"
echo
echo "Backups are configured to run daily at 2 AM and are stored in ${APP_DIR}/backups"
echo
echo "If you provided a domain, your site is accessible at https://${DOMAIN_NAME}"
echo "====================================================" 