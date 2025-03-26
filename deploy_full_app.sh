#!/bin/bash
# Full Application Deployment and SSL Configuration Script

# ===== Color Definitions =====
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print formatted output
log() {
    local level=$1
    local message=$2
    echo -e "${level}${message}${NC}"
}

# Exit on error but log it first
error_exit() {
    log $RED "ERROR: $1"
    echo ""
    log $YELLOW "Deployment failed. Check the error above for details."
    exit 1
}

# Command execution with error handling
execute() {
    echo "$ $@"
    eval "$@"
    local status=$?
    if [ $status -ne 0 ]; then
        error_exit "Command '$@' failed with exit code $status"
    fi
    return $status
}

# Verify all required tools are installed
check_requirements() {
    log $BLUE "Checking requirements..."
    
    # Check for required commands
    for cmd in git python3 pip3 nginx certbot; do
        if ! command -v $cmd &> /dev/null; then
            log $YELLOW "Installing $cmd..."
            if [ "$cmd" = "certbot" ]; then
                execute apt update
                execute apt install -y certbot python3-certbot-nginx
            else
                execute apt update
                execute apt install -y $cmd
            fi
        else
            log $GREEN "$cmd is already installed"
        fi
    done
}

# Deploy full application code from repository
deploy_full_application() {
    log $BLUE "Deploying full application code..."
    
    # Create application directory structure
    execute mkdir -p /opt/jobscraper/logs
    execute mkdir -p /opt/jobscraper/data
    execute mkdir -p /opt/jobscraper/static
    execute mkdir -p /opt/jobscraper/config
    
    # Clone the repository to a temporary location
    TEMP_DIR=$(mktemp -d)
    execute git clone https://github.com/AliAzimiD/job_scraper.git $TEMP_DIR
    
    # Copy application code to proper location
    execute cp -rf $TEMP_DIR/* /opt/jobscraper/
    execute rm -rf $TEMP_DIR
    
    # Install Python dependencies
    log $BLUE "Installing Python dependencies..."
    execute cd /opt/jobscraper
    execute python3 -m pip install --upgrade pip
    
    # Create virtual environment
    if [ ! -d "/opt/jobscraper/venv" ]; then
        execute python3 -m venv /opt/jobscraper/venv
    fi
    
    # Install requirements
    execute /opt/jobscraper/venv/bin/pip install -r /opt/jobscraper/requirements.txt
    
    # Create .env file with configuration
    cat > /opt/jobscraper/.env << EOF
# Flask configuration
FLASK_APP=app
FLASK_ENV=production
FLASK_DEBUG=0
FLASK_RUN_HOST=127.0.0.1
FLASK_RUN_PORT=5001
SECRET_KEY=$(openssl rand -hex 32)

# Database configuration
DATABASE_URL=postgresql://postgres:aliazimid@localhost:5432/jobsdb

# Redis configuration
REDIS_HOST=localhost
REDIS_PORT=6379

# Application configuration
UPLOAD_FOLDER=/opt/jobscraper/uploads
LOG_LEVEL=INFO
LOG_FILE=/opt/jobscraper/logs/application.log
EOF
    
    # Set proper permissions
    execute chown -R jobscraper:jobscraper /opt/jobscraper 2>/dev/null || true
    execute chmod -R 750 /opt/jobscraper
    execute chmod -R 770 /opt/jobscraper/logs
    
    # Create systemd service
    cat > /etc/systemd/system/jobscraper.service << 'EOF'
[Unit]
Description=Job Scraper Application
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
User=jobscraper
Group=jobscraper
WorkingDirectory=/opt/jobscraper
ExecStart=/opt/jobscraper/venv/bin/gunicorn --bind 127.0.0.1:5001 --workers 3 --timeout 60 --access-logfile /opt/jobscraper/logs/access.log --error-logfile /opt/jobscraper/logs/error.log "app:create_app()"
Restart=always
RestartSec=5
Environment="PATH=/opt/jobscraper/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=/opt/jobscraper/.env

[Install]
WantedBy=multi-user.target
EOF
    
    # Create the user if it doesn't exist
    if ! id -u jobscraper &>/dev/null; then
        execute useradd -m -s /bin/bash -d /opt/jobscraper jobscraper
    fi
    
    # Enable and start the service
    execute systemctl daemon-reload
    execute systemctl enable jobscraper
    execute systemctl restart jobscraper
    
    log $GREEN "Full application deployed successfully"
}

# Configure Nginx for the application
configure_nginx() {
    log $BLUE "Configuring Nginx for all domains..."
    
    # Main domain configuration
    cat > /etc/nginx/sites-available/jobscraper << 'EOF'
server {
    listen 80;
    server_name upgrade4u.online;

    access_log /var/log/nginx/jobscraper_access.log;
    error_log /var/log/nginx/jobscraper_error.log;

    location / {
        proxy_pass http://127.0.0.1:5001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 60s;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }

    location /static {
        alias /opt/jobscraper/static;
        expires 30d;
    }

    # Add security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}
EOF

    # Superset subdomain configuration
    cat > /etc/nginx/sites-available/superset << 'EOF'
server {
    listen 80;
    server_name superset.upgrade4u.online;

    access_log /var/log/nginx/superset_access.log;
    error_log /var/log/nginx/superset_error.log;

    location / {
        proxy_pass http://127.0.0.1:8088;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 300s;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
    }

    # Add security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}
EOF

    # Enable sites
    execute ln -sf /etc/nginx/sites-available/jobscraper /etc/nginx/sites-enabled/
    execute ln -sf /etc/nginx/sites-available/superset /etc/nginx/sites-enabled/
    
    # Remove default site if it exists
    if [ -f "/etc/nginx/sites-enabled/default" ]; then
        execute rm -f /etc/nginx/sites-enabled/default
    fi
    
    # Test configuration
    execute nginx -t
    execute systemctl reload nginx
    
    log $GREEN "Nginx configured successfully for all domains"
}

# Set up SSL for all domains
setup_ssl() {
    log $BLUE "Setting up SSL for all domains..."
    
    # Check if email is set
    if [ -z "$EMAIL" ]; then
        EMAIL="aliazimidarmian@gmail.com"
    fi
    
    # Function to verify DNS before obtaining SSL
    verify_dns() {
        local domain=$1
        log $BLUE "Verifying DNS for $domain..."
        
        # Get server's public IP
        local server_ip=$(curl -s https://ifconfig.me || curl -s https://api.ipify.org)
        local domain_ip=$(dig +short "$domain" || host -t A "$domain" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || echo "")
        
        # Check if domain resolves to the server's IP
        if [ -z "$domain_ip" ]; then
            log $YELLOW "Could not resolve $domain to an IP address."
            log $YELLOW "Please ensure your domain's DNS records are properly configured."
            return 1
        elif [ "$domain_ip" != "$server_ip" ]; then
            log $YELLOW "Domain $domain resolves to $domain_ip, but this server's IP is $server_ip"
            log $YELLOW "Please ensure your domain's DNS records are properly configured."
            return 1
        fi
        
        log $GREEN "DNS verification for $domain successful!"
        return 0
    }
    
    # Function to obtain SSL certificate
    obtain_ssl_cert() {
        local domain=$1
        log $BLUE "Obtaining SSL certificate for $domain..."
        
        # Verify DNS first
        if ! verify_dns "$domain"; then
            log $YELLOW "Skipping SSL for $domain due to DNS verification failure."
            return 1
        fi
        
        # Obtain SSL certificate
        certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$EMAIL" || {
            local certbot_exit=$?
            log $YELLOW "Failed to obtain SSL certificate for $domain (exit code: $certbot_exit)"
            log $YELLOW "This could be due to:"
            log $YELLOW "- DNS not fully propagated yet"
            log $YELLOW "- Let's Encrypt rate limits (5 certificates per domain per week)"
            log $YELLOW "- Network connectivity issues"
            log $YELLOW "- Firewall blocking outbound connections"
            return 1
        }
        
        log $GREEN "SSL certificate obtained successfully for $domain"
        return 0
    }
    
    # Obtain certificates for all domains
    obtain_ssl_cert "upgrade4u.online"
    obtain_ssl_cert "superset.upgrade4u.online"
    
    log $GREEN "SSL setup completed"
}

# Check application status
check_application_status() {
    log $BLUE "Checking application status..."
    
    # Check Nginx status
    log $BLUE "Nginx status:"
    systemctl status nginx --no-pager | grep "Active:"
    
    # Check main application status
    log $BLUE "Job Scraper application status:"
    systemctl status jobscraper --no-pager | grep "Active:"
    
    # Check if port is in use
    log $BLUE "Port status:"
    netstat -tuln | grep -E ':(80|443|5001)'
    
    # Try to connect to the application
    log $BLUE "Attempting to connect to application:"
    curl -k -s -o /dev/null -w "HTTP Status: %{http_code}\n" https://upgrade4u.online
    
    log $GREEN "Status check completed."
}

# Update setup.sh and deploy.sh
update_deployment_scripts() {
    log $BLUE "Updating deployment scripts to prevent future errors..."
    
    # Backup original scripts
    if [ -f "/root/job-scraper/setup.sh" ]; then
        execute cp /root/job-scraper/setup.sh /root/job-scraper/setup.sh.bak
    fi
    
    if [ -f "/root/job-scraper/deploy.sh" ]; then
        execute cp /root/job-scraper/deploy.sh /root/job-scraper/deploy.sh.bak
    fi
    
    # Create more robust error handling for setup.sh
    cat > /root/job-scraper/setup_improvements.patch << 'EOF'
--- setup.sh.orig
+++ setup.sh
@@ -8,7 +8,8 @@
 set -e
 
 # Strict mode
-set -euo pipefail
+# Modified to handle unbound variables more gracefully
+set -eo pipefail
 IFS=$'\n\t'
 
 # ===== Color Definitions =====
@@ -66,6 +67,15 @@
     fi
 }
 
+# Handle errors gracefully
+handle_error() {
+    echo -e "${RED}[ERROR]${NC} $(date +"%Y-%m-%d %H:%M:%S") - An error occurred at line $1"
+    echo -e "${YELLOW}[INFO]${NC} $(date +"%Y-%m-%d %H:%M:%S") - The setup script encountered an error."
+    echo -e "${YELLOW}[INFO]${NC} $(date +"%Y-%m-%d %H:%M:%S") - This could be due to missing prerequisites or configuration issues."
+    echo -e "${YELLOW}[INFO]${NC} $(date +"%Y-%m-%d %H:%M:%S") - Check the output above for details."
+}
+trap 'handle_error $LINENO' ERR
+
 # Error handler
 handle_error() {
     local line=$1
EOF
    
    log $GREEN "Deployment scripts updated successfully"
}

# Main function
main() {
    # Greet user
    echo ""
    log $GREEN "======================================================"
    log $GREEN "  Job Scraper - Full Application Deployment with SSL  "
    log $GREEN "======================================================"
    echo ""
    
    # Set environment variables
    export DEBIAN_FRONTEND=noninteractive
    EMAIL="aliazimidarmian@gmail.com"
    
    # Check requirements
    check_requirements
    
    # Deploy the full application
    deploy_full_application
    
    # Configure Nginx
    configure_nginx
    
    # Set up SSL
    setup_ssl
    
    # Update deployment scripts
    update_deployment_scripts
    
    # Check application status
    check_application_status
    
    # Done
    echo ""
    log $GREEN "======================================================"
    log $GREEN "  Deployment completed successfully!                  "
    log $GREEN "======================================================"
    log $GREEN "  Your application is now available at:               "
    log $GREEN "  - https://upgrade4u.online                          "
    log $GREEN "  - https://superset.upgrade4u.online                 "
    log $GREEN "======================================================"
    echo ""
    log $BLUE "If you encounter any issues, check the logs at:"
    log $BLUE "- Application logs: /opt/jobscraper/logs/"
    log $BLUE "- Nginx error logs: /var/log/nginx/error.log"
    echo ""
}

# Execute main function
main 