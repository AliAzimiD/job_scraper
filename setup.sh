#!/bin/bash
# Job Scraper Application Production Setup Script
# This script sets up the Job Scraper application for production use on a VPS

# Exit immediately if a command exits with a non-zero status
set -e

# Strict mode
set -euo pipefail
IFS=$'\n\t'

# ===== Color Definitions =====
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ===== Configuration =====
# These values can be overridden by environment variables
APP_USER=${APP_USER:-"jobscraper"}
APP_GROUP=${APP_GROUP:-"jobscraper"}
APP_HOME=${APP_HOME:-"/opt/jobscraper"}
APP_PORT=${APP_PORT:-5001}
APP_NAME=${APP_NAME:-"jobscraper"}
PYTHON_VERSION=${PYTHON_VERSION:-"3.10"}
POSTGRES_VERSION=${POSTGRES_VERSION:-"15"}
USE_NGINX=${USE_NGINX:-"true"}
USE_SSL=${USE_SSL:-"true"}
DOMAIN_NAME=${DOMAIN_NAME:-"example.com"}
EMAIL=${EMAIL:-"admin@example.com"}
USE_DOCKER=${USE_DOCKER:-"false"}
DB_USER=${DB_USER:-"postgres"}
DB_PASSWORD=${DB_PASSWORD:-"$(openssl rand -hex 16)"}
DB_NAME=${DB_NAME:-"jobsdb"}
DB_HOST=${DB_HOST:-"localhost"}
DB_PORT=${DB_PORT:-5432}
REDIS_HOST=${REDIS_HOST:-"localhost"}
REDIS_PORT=${REDIS_PORT:-6379}
LOG_LEVEL=${LOG_LEVEL:-"INFO"}
USE_SUPERSET=${USE_SUPERSET:-"true"}
SUPERSET_PORT=${SUPERSET_PORT:-8088}
SUPERSET_USER=${SUPERSET_USER:-"admin"}
SUPERSET_PASSWORD=${SUPERSET_PASSWORD:-"$(openssl rand -hex 8)"}
SUPERSET_HOME=${SUPERSET_HOME:-"/opt/superset"}
SUPERSET_DOMAIN=${SUPERSET_DOMAIN:-"superset.$DOMAIN_NAME"}

# ===== Helper Functions =====

# Print formatted output
log() {
    local level=$1
    local message=$2
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    case $level in
        "INFO")
            echo -e "${BLUE}[INFO]${NC} ${timestamp} - $message"
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} ${timestamp} - $message"
            ;;
        "WARNING")
            echo -e "${YELLOW}[WARNING]${NC} ${timestamp} - $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} ${timestamp} - $message" >&2
            ;;
        *)
            echo -e "${timestamp} - $message"
            ;;
    esac
}

# Display section header
section() {
    echo ""
    echo -e "${GREEN}=================================================${NC}"
    echo -e "${GREEN}   $1${NC}"
    echo -e "${GREEN}=================================================${NC}"
    echo ""
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if running as root
is_root() {
    if [ "$(id -u)" -ne 0 ]; then
        return 1
    else
        return 0
    fi
}

# Create secure backup of a file before modifying
backup_file() {
    local file=$1
    if [ -f "$file" ]; then
        local backup="${file}.bak.$(date +%Y%m%d%H%M%S)"
        log "INFO" "Creating backup of $file to $backup"
        cp "$file" "$backup"
        chmod 600 "$backup"
    fi
}

# Error handler
handle_error() {
    local line=$1
    local exit_code=$2
    log "ERROR" "Script failed at line $line with exit code $exit_code"
    log "WARNING" "Please check the logs for details and fix the issue"
    log "INFO" "For assistance, consult the documentation or contact support"
}

# Set up error trap
trap 'handle_error ${LINENO} $?' ERR

# ===== Validation Functions =====

# Check system requirements
check_system_requirements() {
    section "Checking System Requirements"
    
    # Check if script is running as root
    if ! is_root; then
        log "ERROR" "This script must be run as root"
        exit 1
    fi

    # Check operating system
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        if [[ "$ID" == "ubuntu" || "$ID" == "debian" ]]; then
            log "INFO" "Operating system: $PRETTY_NAME"
        else
            log "WARNING" "This script is designed for Ubuntu/Debian. Your OS: $PRETTY_NAME"
            log "WARNING" "The script may not work as expected"
            
            echo -n "Do you want to continue anyway? (y/n): "
            read -r continue_anyway
            if [[ "$continue_anyway" != "y" && "$continue_anyway" != "Y" ]]; then
                log "INFO" "Installation canceled"
                exit 0
            fi
        fi
    else
        log "WARNING" "Unable to detect operating system"
    fi
    
    # Check available disk space (minimum 5GB free)
    local free_space=$(df -m / | tail -1 | awk '{print $4}')
    if [ "$free_space" -lt 5120 ]; then
        log "WARNING" "Low disk space: ${free_space}MB free. Recommended: 5GB minimum"
        
        echo -n "Do you want to continue anyway? (y/n): "
        read -r continue_anyway
        if [[ "$continue_anyway" != "y" && "$continue_anyway" != "Y" ]]; then
            log "INFO" "Installation canceled"
            exit 0
        fi
    else
        log "INFO" "Disk space: ${free_space}MB free"
    fi
    
    # Check available memory (minimum 2GB recommended)
    local total_memory=$(free -m | awk '/Mem:/ {print $2}')
    if [ "$total_memory" -lt 2048 ]; then
        log "WARNING" "Low memory: ${total_memory}MB. Recommended: 2GB minimum"
        
        echo -n "Do you want to continue anyway? (y/n): "
        read -r continue_anyway
        if [[ "$continue_anyway" != "y" && "$continue_anyway" != "Y" ]]; then
            log "INFO" "Installation canceled"
            exit 0
        fi
    else
        log "INFO" "Memory: ${total_memory}MB total"
    fi
    
    log "SUCCESS" "System requirements check completed"
}

# ===== Installation Functions =====

# Update system packages
update_system_packages() {
    section "Updating System Packages"
    
    log "INFO" "Updating package lists"
    apt-get update -qq || {
        log "ERROR" "Failed to update package lists"
        exit 1
    }
    
    log "INFO" "Upgrading system packages"
    apt-get upgrade -y -qq || {
        log "WARNING" "Failed to upgrade some packages, continuing anyway"
    }
    
    log "SUCCESS" "System packages updated"
}

# Install required packages
install_dependencies() {
    section "Installing Dependencies"
    
    local base_packages=(curl wget git software-properties-common apt-transport-https ca-certificates gnupg lsb-release unzip build-essential libssl-dev libffi-dev python3-dev python3-pip python3-venv)
    local postgres_packages=(postgresql-$POSTGRES_VERSION postgresql-contrib postgresql-client-$POSTGRES_VERSION)
    local nginx_packages=(nginx certbot python3-certbot-nginx)
    local redis_packages=(redis-server)
    local monitoring_packages=(prometheus-node-exporter)
    
    log "INFO" "Installing base packages"
    apt-get install -y -qq "${base_packages[@]}" || {
        log "ERROR" "Failed to install base packages"
        exit 1
    }
    
    # Check if Docker should be installed
    if [[ "$USE_DOCKER" == "true" ]]; then
        log "INFO" "Installing Docker and Docker Compose"
        install_docker
    else
        # Add PostgreSQL repository
        log "INFO" "Setting up PostgreSQL repository"
        wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | gpg --dearmor -o /usr/share/keyrings/postgresql-archive-keyring.gpg
        sh -c 'echo "deb [signed-by=/usr/share/keyrings/postgresql-archive-keyring.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
        apt-get update -qq
        
        # Install PostgreSQL
        log "INFO" "Installing PostgreSQL $POSTGRES_VERSION"
        apt-get install -y -qq "${postgres_packages[@]}" || {
            log "ERROR" "Failed to install PostgreSQL"
            exit 1
        }
        
        # Install Redis
        log "INFO" "Installing Redis"
        apt-get install -y -qq "${redis_packages[@]}" || {
            log "ERROR" "Failed to install Redis"
            exit 1
        }
        
        # Install Nginx if needed
        if [[ "$USE_NGINX" == "true" ]]; then
            log "INFO" "Installing Nginx and Certbot"
            apt-get install -y -qq "${nginx_packages[@]}" || {
                log "ERROR" "Failed to install Nginx and Certbot"
                exit 1
            }
        fi
    fi
    
    # Install monitoring tools
    log "INFO" "Installing monitoring tools"
    apt-get install -y -qq "${monitoring_packages[@]}" || {
        log "WARNING" "Failed to install monitoring tools, continuing anyway"
    }
    
    log "SUCCESS" "Dependencies installed"
}

# Install Docker and Docker Compose
install_docker() {
    log "INFO" "Setting up Docker repository"
    
    # Add Docker's official GPG key
    if ! command_exists docker; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io || {
            log "ERROR" "Failed to install Docker"
            exit 1
        }
    else
        log "INFO" "Docker already installed"
    fi
    
    # Install Docker Compose v2
    if ! command_exists docker-compose; then
        log "INFO" "Installing Docker Compose v2"
        mkdir -p /usr/local/lib/docker/cli-plugins/
        curl -SL "https://github.com/docker/compose/releases/download/v2.18.1/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/lib/docker/cli-plugins/docker-compose
        chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
        ln -sf /usr/local/lib/docker/cli-plugins/docker-compose /usr/local/bin/docker-compose
    else
        log "INFO" "Docker Compose already installed"
    fi
    
    # Test Docker installation
    docker --version || {
        log "ERROR" "Docker installation verification failed"
        exit 1
    }
    
    docker-compose --version || {
        log "ERROR" "Docker Compose installation verification failed"
        exit 1
    }
    
    log "SUCCESS" "Docker and Docker Compose installed successfully"
}

# Create application user and directories
setup_application_user() {
    section "Setting Up Application User and Directories"
    
    # Create app user if it doesn't exist
    if ! id -u "$APP_USER" >/dev/null 2>&1; then
        log "INFO" "Creating application user: $APP_USER"
        useradd -m -s /bin/bash -d "$APP_HOME" "$APP_USER" || {
            log "ERROR" "Failed to create application user"
            exit 1
        }
    else
        log "INFO" "User $APP_USER already exists"
    fi
    
    # Create application directories
    log "INFO" "Creating application directories"
    mkdir -p "$APP_HOME"
    mkdir -p "$APP_HOME/logs"
    mkdir -p "$APP_HOME/data"
    mkdir -p "$APP_HOME/backups"
    mkdir -p "$APP_HOME/uploads"
    mkdir -p "$APP_HOME/static"
    mkdir -p "$APP_HOME/config"
    
    # Set ownership and permissions
    log "INFO" "Setting ownership and permissions"
    chown -R "$APP_USER:$APP_GROUP" "$APP_HOME"
    chmod -R 750 "$APP_HOME"
    chmod -R 770 "$APP_HOME/logs"
    chmod -R 770 "$APP_HOME/uploads"
    
    log "SUCCESS" "Application user and directories set up"
}

# Clone or update application code
setup_application_code() {
    section "Setting Up Application Code"
    
    # Check if the current directory has the application code
    if [ -f "main.py" ] && [ -d "app" ]; then
        log "INFO" "Application code found in current directory"
        log "INFO" "Copying application code to $APP_HOME"
        
        rsync -a --exclude=".git" --exclude="venv" --exclude="__pycache__" --exclude="*.pyc" . "$APP_HOME/" || {
            log "ERROR" "Failed to copy application code"
            exit 1
        }
    else
        log "ERROR" "Application code not found in current directory"
        log "INFO" "Please run this script from the application root directory"
        exit 1
    fi
    
    # Set ownership of application files
    chown -R "$APP_USER:$APP_GROUP" "$APP_HOME"
    
    log "SUCCESS" "Application code set up"
}

# Set up Python virtual environment
setup_virtualenv() {
    section "Setting Up Python Virtual Environment"
    
    log "INFO" "Creating Python virtual environment"
    su - "$APP_USER" -c "cd $APP_HOME && python3 -m venv venv" || {
        log "ERROR" "Failed to create virtual environment"
        exit 1
    }
    
    log "INFO" "Installing Python dependencies"
    su - "$APP_USER" -c "cd $APP_HOME && source venv/bin/activate && pip install --upgrade pip && pip install wheel && pip install -r requirements.txt" || {
        log "ERROR" "Failed to install Python dependencies"
        exit 1
    }
    
    log "SUCCESS" "Python virtual environment set up"
}

# Configure the application
configure_application() {
    section "Configuring Application"
    
    log "INFO" "Creating .env file"
    if [ ! -f "$APP_HOME/.env" ]; then
        # Generate a secure secret key
        local secret_key=$(openssl rand -hex 32)
        
        cat > "$APP_HOME/.env" << EOF
# Flask configuration
FLASK_APP=app
FLASK_ENV=production
FLASK_DEBUG=0
FLASK_RUN_HOST=127.0.0.1
FLASK_RUN_PORT=$APP_PORT
SECRET_KEY=$secret_key

# Database configuration
DATABASE_URL=postgresql://$DB_USER:$DB_PASSWORD@$DB_HOST:$DB_PORT/$DB_NAME

# Redis configuration
REDIS_HOST=$REDIS_HOST
REDIS_PORT=$REDIS_PORT

# Application configuration
UPLOAD_FOLDER=$APP_HOME/uploads
LOG_LEVEL=$LOG_LEVEL
LOG_FILE=$APP_HOME/logs/application.log
EOF
        
        chown "$APP_USER:$APP_GROUP" "$APP_HOME/.env"
        chmod 640 "$APP_HOME/.env"
        
        log "INFO" "Environment configuration created"
    else
        log "INFO" ".env file already exists, skipping"
    fi
    
    log "SUCCESS" "Application configured"
}

# Set up database
setup_database() {
    section "Setting Up Database"
    
    if [[ "$USE_DOCKER" == "true" ]]; then
        log "INFO" "Database will be managed via Docker"
        return 0
    fi
    
    log "INFO" "Configuring PostgreSQL"
    
    # Ensure PostgreSQL is running
    systemctl is-active --quiet postgresql || {
        log "INFO" "Starting PostgreSQL service"
        systemctl start postgresql
    }
    
    # Enable PostgreSQL on boot
    systemctl enable postgresql
    
    # Create database and user if they don't exist
    if ! su - postgres -c "psql -lqt | cut -d \| -f 1 | grep -qw $DB_NAME"; then
        log "INFO" "Creating database: $DB_NAME"
        su - postgres -c "createdb $DB_NAME" || {
            log "ERROR" "Failed to create database"
            exit 1
        }
        
        log "INFO" "Creating database user: $DB_USER"
        # Check if user already exists
        if ! su - postgres -c "psql -t -c '\du' | grep -qw $DB_USER"; then
            su - postgres -c "createuser $DB_USER" || {
                log "ERROR" "Failed to create database user"
                exit 1
            }
        fi
        
        log "INFO" "Setting user password and permissions"
        su - postgres -c "psql -c \"ALTER USER $DB_USER WITH ENCRYPTED PASSWORD '$DB_PASSWORD'\"" || {
            log "ERROR" "Failed to set user password"
            exit 1
        }
        
        su - postgres -c "psql -c \"GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER\"" || {
            log "ERROR" "Failed to grant privileges"
            exit 1
        }
    else
        log "INFO" "Database $DB_NAME already exists"
    fi
    
    # Initialize database tables by running database migrations
    log "INFO" "Initializing database"
    if [ -f "$APP_HOME/app/db/init_db.py" ]; then
        su - "$APP_USER" -c "cd $APP_HOME && source venv/bin/activate && python3 -m app.db.init_db" || {
            log "ERROR" "Failed to initialize database"
            exit 1
        }
    else
        log "WARNING" "Database initialization script not found"
        log "INFO" "You may need to initialize the database manually"
    fi
    
    log "SUCCESS" "Database set up"
}

# Set up Redis
setup_redis() {
    section "Setting Up Redis"
    
    if [[ "$USE_DOCKER" == "true" ]]; then
        log "INFO" "Redis will be managed via Docker"
        return 0
    fi
    
    log "INFO" "Configuring Redis"
    
    # Ensure Redis is running
    systemctl is-active --quiet redis-server || {
        log "INFO" "Starting Redis service"
        systemctl start redis-server
    }
    
    # Enable Redis on boot
    systemctl enable redis-server
    
    # Basic Redis security configuration
    backup_file "/etc/redis/redis.conf"
    
    # Disable Redis listening on all interfaces (bind to localhost only)
    sed -i '/^bind/ c\bind 127.0.0.1' /etc/redis/redis.conf
    
    # Restart Redis to apply configuration
    log "INFO" "Restarting Redis service"
    systemctl restart redis-server
    
    log "SUCCESS" "Redis set up"
}

# Set up Nginx
setup_nginx() {
    section "Setting Up Nginx"
    
    if [[ "$USE_NGINX" != "true" || "$USE_DOCKER" == "true" ]]; then
        if [[ "$USE_DOCKER" == "true" ]]; then
            log "INFO" "Nginx will be managed via Docker"
        else
            log "INFO" "Nginx setup skipped as per configuration"
        fi
        return 0
    fi
    
    log "INFO" "Configuring Nginx"
    
    # Create Nginx config
    cat > "/etc/nginx/sites-available/$APP_NAME" << EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location /static {
        alias $APP_HOME/static;
        expires 30d;
    }

    location /uploads {
        alias $APP_HOME/uploads;
        internal;  # Prevent direct access
    }

    client_max_body_size 10M;  # Adjust based on your needs

    # Security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}
EOF
    
    # Enable the site
    ln -sf "/etc/nginx/sites-available/$APP_NAME" "/etc/nginx/sites-enabled/" || {
        log "ERROR" "Failed to enable Nginx site"
        exit 1
    }
    
    # Remove default site if it exists
    if [ -f "/etc/nginx/sites-enabled/default" ]; then
        rm "/etc/nginx/sites-enabled/default"
    fi
    
    # Test Nginx configuration
    nginx -t || {
        log "ERROR" "Nginx configuration test failed"
        exit 1
    }
    
    # Restart Nginx
    systemctl restart nginx || {
        log "ERROR" "Failed to restart Nginx"
        exit 1
    }
    
    # Enable Nginx on boot
    systemctl enable nginx
    
    # Set up SSL if requested
    if [[ "$USE_SSL" == "true" ]]; then
        setup_ssl
    else
        log "INFO" "SSL setup skipped as per configuration"
    fi
    
    log "SUCCESS" "Nginx set up"
}

# Set up SSL with Let's Encrypt
setup_ssl() {
    log "INFO" "Setting up SSL with Let's Encrypt"
    
    if [ -z "$DOMAIN_NAME" ]; then
        log "ERROR" "Domain name not provided, cannot set up SSL"
        log "INFO" "Please set DOMAIN_NAME and run the SSL setup again"
        return 1
    fi
    
    if [ -z "$EMAIL" ]; then
        log "ERROR" "Email not provided, cannot set up SSL"
        log "INFO" "Please set EMAIL and run the SSL setup again"
        return 1
    fi
    
    # Check if domain resolves to this server's IP
    local server_ip=$(curl -s https://ifconfig.me || curl -s https://api.ipify.org)
    local domain_ip=$(dig +short "$DOMAIN_NAME" A || host -t A "$DOMAIN_NAME" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' || nslookup "$DOMAIN_NAME" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | tail -1)
    
    if [[ -z "$domain_ip" ]]; then
        log "WARNING" "Could not resolve domain $DOMAIN_NAME to an IP address"
        log "INFO" "Please ensure your domain's DNS records are properly configured to point to this server"
        log "INFO" "You can run the SSL setup later with: certbot --nginx -d $DOMAIN_NAME"
        return 1
    elif [[ "$domain_ip" != "$server_ip" ]]; then
        log "WARNING" "Domain $DOMAIN_NAME resolves to $domain_ip, but this server's IP is $server_ip"
        log "INFO" "Please ensure your domain's DNS records are properly configured to point to this server"
        log "INFO" "You can run the SSL setup later with: certbot --nginx -d $DOMAIN_NAME"
        return 1
    fi
    
    # Try to obtain SSL certificate
    certbot --nginx -d "$DOMAIN_NAME" --non-interactive --agree-tos -m "$EMAIL" || {
        log "WARNING" "Failed to obtain SSL certificate"
        log "INFO" "This could be due to:"
        log "INFO" "  - DNS not fully propagated yet"
        log "INFO" "  - Let's Encrypt rate limits (5 certificates per domain per week)"
        log "INFO" "  - Network connectivity issues"
        log "INFO" "  - Firewall blocking outbound connections"
        log "INFO" "You can try again later with: certbot --nginx -d $DOMAIN_NAME"
        return 1
    }
    
    log "SUCCESS" "SSL certificate obtained successfully"
    
    # If Superset is enabled, also set up SSL for the Superset subdomain
    if [[ "$USE_SUPERSET" == "true" ]]; then
        log "INFO" "Setting up SSL for Superset subdomain"
        setup_ssl_for_domain "${SUPERSET_DOMAIN:-"superset.$DOMAIN_NAME"}"
    fi
    
    return 0
}

# Helper function to set up SSL for a specific domain
setup_ssl_for_domain() {
    local domain=$1
    
    log "INFO" "Setting up SSL for $domain with Let's Encrypt"
    
    if [ -z "$EMAIL" ]; then
        log "ERROR" "Email not provided, cannot set up SSL"
        log "INFO" "Please set EMAIL and run the SSL setup again"
        return 1
    fi
    
    # Try to obtain SSL certificate
    certbot --nginx -d "$domain" --non-interactive --agree-tos -m "$EMAIL" || {
        log "WARNING" "Failed to obtain SSL certificate for $domain"
        log "INFO" "This could be due to:"
        log "INFO" "  - DNS not fully propagated yet"
        log "INFO" "  - Let's Encrypt rate limits (5 certificates per domain per week)"
        log "INFO" "  - Network connectivity issues"
        log "INFO" "  - Firewall blocking outbound connections"
        log "INFO" "You can try again later with: certbot --nginx -d $domain"
        return 1
    }
    
    log "SUCCESS" "SSL certificate obtained successfully for $domain"
    return 0
}

# Set up systemd service
setup_systemd_service() {
    section "Setting Up Systemd Service"
    
    if [[ "$USE_DOCKER" == "true" ]]; then
        log "INFO" "Systemd service for application will be skipped (using Docker)"
        setup_docker_service
        return 0
    fi
    
    log "INFO" "Creating systemd service for application"
    
    cat > "/etc/systemd/system/$APP_NAME.service" << EOF
[Unit]
Description=Job Scraper Application
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
User=$APP_USER
Group=$APP_GROUP
WorkingDirectory=$APP_HOME
ExecStart=$APP_HOME/venv/bin/gunicorn --bind 127.0.0.1:$APP_PORT --workers 3 --timeout 60 --access-logfile $APP_HOME/logs/access.log --error-logfile $APP_HOME/logs/error.log "app:create_app()"
Restart=always
RestartSec=5
Environment="PATH=$APP_HOME/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EnvironmentFile=$APP_HOME/.env

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd
    systemctl daemon-reload || {
        log "ERROR" "Failed to reload systemd"
        exit 1
    }
    
    # Enable and start the service
    systemctl enable "$APP_NAME.service" || {
        log "ERROR" "Failed to enable service"
        exit 1
    }
    
    systemctl start "$APP_NAME.service" || {
        log "ERROR" "Failed to start service"
        exit 1
    }
    
    log "SUCCESS" "Systemd service set up"
}

# Set up Docker service
setup_docker_service() {
    section "Setting Up Docker Services"
    
    log "INFO" "Creating Docker Compose service"
    
    cat > "/etc/systemd/system/$APP_NAME-docker.service" << EOF
[Unit]
Description=Job Scraper Docker Compose Service
Requires=docker.service
After=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$APP_HOME
ExecStart=/usr/local/bin/docker-compose up -d
ExecStop=/usr/local/bin/docker-compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd
    systemctl daemon-reload || {
        log "ERROR" "Failed to reload systemd"
        exit 1
    }
    
    # Enable the service
    systemctl enable "$APP_NAME-docker.service" || {
        log "ERROR" "Failed to enable Docker Compose service"
        exit 1
    }
    
    log "INFO" "Starting Docker Compose service"
    systemctl start "$APP_NAME-docker.service" || {
        log "ERROR" "Failed to start Docker Compose service"
        exit 1
    }
    
    log "SUCCESS" "Docker Compose service set up"
}

# Set up monitoring (Prometheus Node Exporter)
setup_monitoring() {
    section "Setting Up Monitoring"
    
    log "INFO" "Configuring Prometheus Node Exporter"
    
    # Ensure Node Exporter is running
    systemctl is-active --quiet prometheus-node-exporter || {
        log "INFO" "Starting Prometheus Node Exporter"
        systemctl start prometheus-node-exporter
    }
    
    # Enable Node Exporter on boot
    systemctl enable prometheus-node-exporter
    
    log "INFO" "Prometheus Node Exporter is running on port 9100"
    
    log "SUCCESS" "Monitoring set up"
}

# Set up backups
setup_backups() {
    section "Setting Up Backups"
    
    log "INFO" "Creating backup script"
    
    cat > "$APP_HOME/scripts/backup.sh" << 'EOF'
#!/bin/bash
# Backup script for Job Scraper Application

# Load environment variables
source $(dirname "$0")/../.env

# Set backup directory
BACKUP_DIR=$(dirname "$0")/../backups
DATE=$(date +"%Y%m%d_%H%M%S")
BACKUP_FILE="${BACKUP_DIR}/jobsdb_backup_${DATE}.sql"

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Database backup
echo "Creating database backup..."
PGPASSWORD=$DB_PASSWORD pg_dump -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -F p > "$BACKUP_FILE"

# Compress backup
echo "Compressing backup..."
gzip "$BACKUP_FILE"

# Rotate backups (keep last 7 backups)
echo "Rotating backups..."
ls -tp "$BACKUP_DIR"/jobsdb_backup_*.sql.gz | grep -v '/$' | tail -n +8 | xargs -I {} rm -- {}

echo "Backup completed: ${BACKUP_FILE}.gz"
EOF
    
    chmod +x "$APP_HOME/scripts/backup.sh"
    chown "$APP_USER:$APP_GROUP" "$APP_HOME/scripts/backup.sh"
    
    log "INFO" "Setting up scheduled backups with cron"
    
    # Add cron job for daily backups at 2 AM
    (crontab -u "$APP_USER" -l 2>/dev/null || echo "") | grep -v "$APP_HOME/scripts/backup.sh" | { cat; echo "0 2 * * * $APP_HOME/scripts/backup.sh > $APP_HOME/logs/backup.log 2>&1"; } | crontab -u "$APP_USER" -
    
    log "SUCCESS" "Backups set up"
}

# Set up security
setup_security() {
    section "Setting Up Security"
    
    log "INFO" "Configuring basic security settings"
    
    # Set up firewall (ufw)
    if command_exists ufw; then
        log "INFO" "Configuring firewall (ufw)"
        
        # Allow SSH
        ufw allow ssh
        
        # Allow HTTP/HTTPS
        ufw allow http
        ufw allow https
        
        # Allow application port only from localhost
        ufw allow from 127.0.0.1 to any port "$APP_PORT"
        
        # Enable firewall if it's not already enabled
        if ! ufw status | grep -q "Status: active"; then
            log "INFO" "Enabling firewall"
            echo "y" | ufw enable
        else
            log "INFO" "Firewall is already active"
        fi
    else
        log "WARNING" "ufw not installed, skipping firewall configuration"
    fi
    
    # Set secure permissions for sensitive files
    log "INFO" "Setting secure permissions for sensitive files"
    chmod 640 "$APP_HOME/.env"
    
    # Recommendations for additional security
    log "INFO" "Security recommendations:"
    log "INFO" "- Use a strong password for SSH access"
    log "INFO" "- Consider setting up SSH key authentication"
    log "INFO" "- Regularly update the system with 'apt update && apt upgrade'"
    log "INFO" "- Consider setting up a more advanced firewall configuration"
    log "INFO" "- Monitor system logs regularly"
    
    log "SUCCESS" "Basic security set up"
}

# Verify installation
verify_installation() {
    section "Verifying Installation"
    
    local success=true
    
    log "INFO" "Checking application service status"
    if [[ "$USE_DOCKER" == "true" ]]; then
        if ! systemctl is-active --quiet "$APP_NAME-docker.service"; then
            log "ERROR" "Docker Compose service is not running"
            success=false
        else
            log "SUCCESS" "Docker Compose service is running"
        fi
    else
        if ! systemctl is-active --quiet "$APP_NAME.service"; then
            log "ERROR" "Application service is not running"
            success=false
        else
            log "SUCCESS" "Application service is running"
        fi
    fi
    
    log "INFO" "Checking database connection"
    if [[ "$USE_DOCKER" != "true" ]]; then
        if ! su - "$APP_USER" -c "cd $APP_HOME && source venv/bin/activate && python3 -c 'from app.db.manager import DatabaseManager; db = DatabaseManager(); print(\"Database connection successful\")' 2>/dev/null | grep -q 'Database connection successful'"; then
            log "WARNING" "Database connection check failed"
            success=false
        else
            log "SUCCESS" "Database connection check passed"
        fi
    fi
    
    log "INFO" "Checking Nginx configuration (if applicable)"
    if [[ "$USE_NGINX" == "true" && "$USE_DOCKER" != "true" ]]; then
        if ! nginx -t >/dev/null 2>&1; then
            log "ERROR" "Nginx configuration is invalid"
            success=false
        else
            log "SUCCESS" "Nginx configuration is valid"
        fi
    fi
    
    if $success; then
        log "SUCCESS" "Installation verification completed successfully"
    else
        log "WARNING" "Some verification checks failed"
        log "INFO" "Please check the logs and fix any issues"
    fi
}

# Set up Apache Superset
setup_superset() {
    section "Setting Up Apache Superset"
    
    if [[ "$USE_SUPERSET" != "true" ]]; then
        log "INFO" "Superset setup skipped as per configuration"
        return 0
    fi
    
    if [[ "$USE_DOCKER" == "true" ]]; then
        setup_superset_docker
        return 0
    fi
    
    log "INFO" "Installing Apache Superset dependencies"
    
    # Install required system packages for Superset
    local superset_deps=(build-essential libssl-dev libffi-dev python3-dev python3-pip libsasl2-dev libldap2-dev default-libmysqlclient-dev)
    apt-get install -y -qq "${superset_deps[@]}" || {
        log "ERROR" "Failed to install Superset dependencies"
        exit 1
    }
    
    # Create Superset user if different from application user
    if [[ "$APP_USER" != "superset" ]]; then
        if ! id -u "superset" >/dev/null 2>&1; then
            log "INFO" "Creating dedicated Superset user"
            useradd -m -s /bin/bash -d "$SUPERSET_HOME" "superset" || {
                log "ERROR" "Failed to create Superset user"
                exit 1
            }
        else
            log "INFO" "Superset user already exists"
        fi
    else
        log "INFO" "Using application user for Superset"
    fi
    
    # Create Superset directories
    log "INFO" "Creating Superset directories"
    mkdir -p "$SUPERSET_HOME"
    mkdir -p "$SUPERSET_HOME/logs"
    mkdir -p "$SUPERSET_HOME/config"
    
    # Set ownership and permissions
    log "INFO" "Setting ownership and permissions for Superset"
    chown -R superset:superset "$SUPERSET_HOME"
    chmod -R 750 "$SUPERSET_HOME"
    
    # Install Superset in a virtual environment
    log "INFO" "Creating Superset virtual environment"
    su - superset -c "cd $SUPERSET_HOME && python3 -m venv venv" || {
        log "ERROR" "Failed to create Superset virtual environment"
        exit 1
    }
    
    log "INFO" "Installing Apache Superset"
    su - superset -c "cd $SUPERSET_HOME && source venv/bin/activate && pip install --upgrade pip && pip install apache-superset psycopg2-binary" || {
        log "ERROR" "Failed to install Apache Superset"
        exit 1
    }
    
    # Initialize Superset database
    log "INFO" "Initializing Superset database"

    # Create a secure SECRET_KEY first
    SUPERSET_SECRET_KEY=$(openssl rand -base64 42)

    # Create Superset config with secure key
    cat > "$SUPERSET_HOME/config/superset_config.py" << EOF
import os

# Superset specific configuration
SUPERSET_WEBSERVER_PORT = ${SUPERSET_PORT}
SUPERSET_WEBSERVER_TIMEOUT = 300
SECRET_KEY = '${SUPERSET_SECRET_KEY}'

# Flask App Builder configuration
APP_NAME = "Job Scraper Analytics"
APP_ICON = "/static/assets/images/superset-logo-horiz.png"
FAVICON = "/static/assets/images/favicon.png"

# Database connection to Job Scraper database
SQLALCHEMY_CUSTOM_PASSWORD_STORE = {}
SQLALCHEMY_CUSTOM_PASSWORD_STORE['jobsdb'] = '${DB_PASSWORD}'

# Example of a database connection
SQLALCHEMY_DATABASE_URI = 'sqlite:///${SUPERSET_HOME}/superset.db'

# Add job scraper database connection string
ADDITIONAL_DATABASE_URI = 'postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}'
EOF

    chown superset:superset "$SUPERSET_HOME/config/superset_config.py"
    chmod 640 "$SUPERSET_HOME/config/superset_config.py"

    # Run database initialization with config path set
    su - superset -c "cd $SUPERSET_HOME && source venv/bin/activate && \
        export FLASK_APP=superset && \
        export SUPERSET_CONFIG_PATH=$SUPERSET_HOME/config/superset_config.py && \
        superset db upgrade" || {
        log "ERROR" "Failed to initialize Superset database"
        exit 1
    }

    # Create admin user
    log "INFO" "Creating Superset admin user"
    su - superset -c "cd $SUPERSET_HOME && source venv/bin/activate && \
        export FLASK_APP=superset && \
        export SUPERSET_CONFIG_PATH=$SUPERSET_HOME/config/superset_config.py && \
        superset fab create-admin \
            --username $SUPERSET_USER \
            --firstname Admin \
            --lastname User \
            --email $EMAIL \
            --password $SUPERSET_PASSWORD" || {
        log "ERROR" "Failed to create Superset admin user"
        exit 1
    }

    # Load examples and initialize roles
    log "INFO" "Setting up Superset initial configuration"
    su - superset -c "cd $SUPERSET_HOME && source venv/bin/activate && \
        export FLASK_APP=superset && \
        export SUPERSET_CONFIG_PATH=$SUPERSET_HOME/config/superset_config.py && \
        superset init" || {
        log "WARNING" "Failed to initialize Superset examples"
    }

    # Create a script to add the database connection
    cat > "$SUPERSET_HOME/scripts/add_jobsdb.py" << 'EOF'
#!/usr/bin/env python3
from superset import db
from superset.models.core import Database
import os

# Get database connection string from environment
conn_string = os.environ.get('DB_CONNECTION_STRING')
db_name = os.environ.get('DB_NAME', 'Job Scraper DB')
db_description = "Job Scraper Database with scraped job listings"

# Check if the database already exists
existing_db = db.session.query(Database).filter_by(database_name=db_name).first()

if not existing_db:
    # Create a new database entry
    new_db = Database(
        database_name=db_name,
        sqlalchemy_uri=conn_string,
        cache_timeout=None,
        expose_in_sqllab=True,
        allow_csv_upload=False,
        allow_ctas=True,
        allow_cvas=True,
        allow_dml=False,
        allow_multi_schema_metadata_fetch=True,
        description=db_description
    )
    db.session.add(new_db)
    db.session.commit()
    print(f"Added database connection: {db_name}")
else:
    # Update existing database
    existing_db.sqlalchemy_uri = conn_string
    existing_db.description = db_description
    db.session.commit()
    print(f"Updated database connection: {db_name}")
EOF

    chmod +x "$SUPERSET_HOME/scripts/add_jobsdb.py"
    chown superset:superset "$SUPERSET_HOME/scripts/add_jobsdb.py"
    
    # Execute the script to add the database connection
    log "INFO" "Adding Job Scraper database to Superset"
    su - superset -c "cd $SUPERSET_HOME && source venv/bin/activate && \
        export PYTHONPATH=$SUPERSET_HOME:$PYTHONPATH && \
        export FLASK_APP=superset && \
        export SUPERSET_CONFIG_PATH=$SUPERSET_HOME/config/superset_config.py && \
        export DB_CONNECTION_STRING='postgresql://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}' && \
        export DB_NAME='Job Scraper DB' && \
        python3 $SUPERSET_HOME/scripts/add_jobsdb.py" || {
        log "WARNING" "Failed to add database connection to Superset"
    }

    # Create a systemd service for Superset
    log "INFO" "Creating systemd service for Superset"
    
    cat > "/etc/systemd/system/superset.service" << EOF
[Unit]
Description=Apache Superset
After=network.target postgresql.service redis-server.service
Wants=postgresql.service redis-server.service

[Service]
User=superset
Group=superset
WorkingDirectory=$SUPERSET_HOME
Environment=PYTHONPATH=$SUPERSET_HOME
Environment=SUPERSET_CONFIG_PATH=$SUPERSET_HOME/config/superset_config.py
ExecStart=$SUPERSET_HOME/venv/bin/gunicorn -w 8 --timeout 120 -b 0.0.0.0:$SUPERSET_PORT --limit-request-line 0 --limit-request-field_size 0 "superset.app:create_app()"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd
    systemctl daemon-reload || {
        log "ERROR" "Failed to reload systemd"
        exit 1
    }
    
    # Enable and start the service
    systemctl enable superset.service || {
        log "ERROR" "Failed to enable Superset service"
        exit 1
    }
    
    systemctl start superset.service || {
        log "ERROR" "Failed to start Superset service"
        exit 1
    }
    
    # Configure Nginx for Superset if Nginx is used
    if [[ "$USE_NGINX" == "true" ]]; then
        log "INFO" "Configuring Nginx for Superset"
        
        cat > "/etc/nginx/sites-available/superset" << EOF
server {
    listen 80;
    server_name ${SUPERSET_DOMAIN:-"superset.$DOMAIN_NAME"};

    location / {
        proxy_pass http://127.0.0.1:$SUPERSET_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    client_max_body_size 100M;

    # Security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}
EOF
        
        # Enable the site
        ln -sf "/etc/nginx/sites-available/superset" "/etc/nginx/sites-enabled/" || {
            log "ERROR" "Failed to enable Nginx configuration for Superset"
            exit 1
        }
        
        # Test Nginx configuration
        nginx -t || {
            log "ERROR" "Nginx configuration test failed"
            exit 1
        }
        
        # Restart Nginx
        systemctl restart nginx || {
            log "ERROR" "Failed to restart Nginx"
            exit 1
        }
        
        # Set up SSL for Superset subdomain if SSL is enabled
        if [[ "$USE_SSL" == "true" ]]; then
            setup_ssl_for_domain "${SUPERSET_DOMAIN:-"superset.$DOMAIN_NAME"}"
        fi
    fi
    
    log "SUCCESS" "Apache Superset set up successfully"
    log "INFO" "Superset admin credentials:"
    log "INFO" "Username: $SUPERSET_USER"
    log "INFO" "Password: $SUPERSET_PASSWORD"
    
    # Store credentials in a secure file
    if [[ ! -d "$APP_HOME/credentials" ]]; then
        mkdir -p "$APP_HOME/credentials"
        chmod 700 "$APP_HOME/credentials"
        chown "$APP_USER:$APP_GROUP" "$APP_HOME/credentials"
    fi
    
    cat > "$APP_HOME/credentials/superset_credentials.txt" << EOF
Superset Admin Credentials
------------------------
URL: http://${SUPERSET_DOMAIN:-"superset.$DOMAIN_NAME"}
Username: $SUPERSET_USER
Password: $SUPERSET_PASSWORD
Created: $(date)

Keep this information secure!
EOF
    
    chmod 600 "$APP_HOME/credentials/superset_credentials.txt"
    chown "$APP_USER:$APP_GROUP" "$APP_HOME/credentials/superset_credentials.txt"
}

# Set up Superset with Docker
setup_superset_docker() {
    log "INFO" "Setting up Apache Superset with Docker"
    
    # Create directory for Superset configuration
    mkdir -p "$APP_HOME/docker/superset"
    mkdir -p "$APP_HOME/docker/superset/config"
    
    # Create a secure random key for Superset
    SUPERSET_DOCKER_SECRET_KEY=$(openssl rand -base64 42)

    # Create Superset configuration for Docker
    cat > "$APP_HOME/docker/superset/config/superset_config.py" << EOF
import os

# Superset specific configuration
SUPERSET_WEBSERVER_PORT = 8088
SUPERSET_WEBSERVER_TIMEOUT = 300
SECRET_KEY = '${SUPERSET_DOCKER_SECRET_KEY}'

# Flask App Builder configuration
APP_NAME = "Job Scraper Analytics"
APP_ICON = "/static/assets/images/superset-logo-horiz.png"
FAVICON = "/static/assets/images/favicon.png"

# Database configuration
SQLALCHEMY_DATABASE_URI = 'sqlite:////app/superset_home/superset.db'

# Job Scraper database connection
SQLALCHEMY_CUSTOM_PASSWORD_STORE = {}
SQLALCHEMY_CUSTOM_PASSWORD_STORE['jobsdb'] = '${DB_PASSWORD}'
EOF
    
    # Create Docker Compose entry for Superset
    cat > "$APP_HOME/docker/superset/docker-compose.yml" << EOF
version: '3'
services:
  superset:
    image: apache/superset:latest
    container_name: superset
    ports:
      - "${SUPERSET_PORT}:8088"
    environment:
      - SUPERSET_SECRET_KEY=${SUPERSET_DOCKER_SECRET_KEY}
      - ADMIN_USERNAME=${SUPERSET_USER}
      - ADMIN_EMAIL=${EMAIL}
      - ADMIN_PASSWORD=${SUPERSET_PASSWORD}
    volumes:
      - ${APP_HOME}/docker/superset/config/superset_config.py:/app/pythonpath/superset_config.py
      - superset_home:/app/superset_home
    restart: always
    networks:
      - job_scraper_network

networks:
  job_scraper_network:
    external: true

volumes:
  superset_home:
EOF
    
    # Create initialization script
    cat > "$APP_HOME/docker/superset/init.sh" << 'EOF'
#!/bin/bash
set -e

# Wait for Superset to be ready
echo "Waiting for Superset to be ready..."
sleep 10

# Initialize Superset database with config path set
docker exec -it superset bash -c "export FLASK_APP=superset && export SUPERSET_CONFIG_PATH=/app/pythonpath/superset_config.py && superset db upgrade"

# Create admin user if not exists
docker exec -it superset bash -c "export FLASK_APP=superset && export SUPERSET_CONFIG_PATH=/app/pythonpath/superset_config.py && superset fab create-admin \
    --username \"$ADMIN_USERNAME\" \
    --firstname Admin \
    --lastname User \
    --email \"$ADMIN_EMAIL\" \
    --password \"$ADMIN_PASSWORD\""

# Initialize Superset roles and examples
docker exec -it superset bash -c "export FLASK_APP=superset && export SUPERSET_CONFIG_PATH=/app/pythonpath/superset_config.py && superset init"

# Add Job Scraper database to Superset
docker exec -it superset bash -c "export FLASK_APP=superset && export SUPERSET_CONFIG_PATH=/app/pythonpath/superset_config.py && superset set-database-uri \
    --database-name \"Job Scraper DB\" \
    --uri \"postgresql://$DB_USER:$DB_PASSWORD@postgres:5432/$DB_NAME\" \
    --expose-in-sqllab \
    --allow-run-async \
    --allow-ctas \
    --allow-cvas \
    --allow-dml"

echo "Superset initialization completed!"
EOF
    
    chmod +x "$APP_HOME/docker/superset/init.sh"
    
    log "INFO" "Starting Superset container"
    cd "$APP_HOME/docker/superset" && docker-compose up -d || {
        log "ERROR" "Failed to start Superset container"
        exit 1
    }
    
    # Run initialization script
    log "INFO" "Initializing Superset"
    source "$APP_HOME/docker/superset/init.sh" || {
        log "WARNING" "Failed to initialize Superset"
        log "INFO" "You can manually initialize it later with: $APP_HOME/docker/superset/init.sh"
    }
    
    # Configure Nginx for Superset if Nginx is used
    if [[ "$USE_NGINX" == "true" ]]; then
        log "INFO" "Configuring Nginx for Superset"
        
        cat > "/etc/nginx/sites-available/superset" << EOF
server {
    listen 80;
    server_name ${SUPERSET_DOMAIN:-"superset.$DOMAIN_NAME"};

    location / {
        proxy_pass http://127.0.0.1:$SUPERSET_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    client_max_body_size 100M;

    # Security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}
EOF
        
        # Enable the site
        ln -sf "/etc/nginx/sites-available/superset" "/etc/nginx/sites-enabled/" || {
            log "ERROR" "Failed to enable Nginx configuration for Superset"
            exit 1
        }
        
        # Test Nginx configuration
        nginx -t || {
            log "ERROR" "Nginx configuration test failed"
            exit 1
        }
        
        # Restart Nginx
        systemctl restart nginx || {
            log "ERROR" "Failed to restart Nginx"
            exit 1
        }
        
        # Set up SSL for Superset subdomain if SSL is enabled
        if [[ "$USE_SSL" == "true" ]]; then
            setup_ssl_for_domain "${SUPERSET_DOMAIN:-"superset.$DOMAIN_NAME"}"
        fi
    fi
    
    log "SUCCESS" "Apache Superset (Docker) set up successfully"
    log "INFO" "Superset admin credentials:"
    log "INFO" "Username: $SUPERSET_USER"
    log "INFO" "Password: $SUPERSET_PASSWORD"
    
    # Store credentials in a secure file
    if [[ ! -d "$APP_HOME/credentials" ]]; then
        mkdir -p "$APP_HOME/credentials"
        chmod 700 "$APP_HOME/credentials"
        chown "$APP_USER:$APP_GROUP" "$APP_HOME/credentials"
    fi
    
    cat > "$APP_HOME/credentials/superset_credentials.txt" << EOF
Superset Admin Credentials
------------------------
URL: http://${SUPERSET_DOMAIN:-"superset.$DOMAIN_NAME"}
Username: $SUPERSET_USER
Password: $SUPERSET_PASSWORD
Created: $(date)

Keep this information secure!
EOF
    
    chmod 600 "$APP_HOME/credentials/superset_credentials.txt"
    chown "$APP_USER:$APP_GROUP" "$APP_HOME/credentials/superset_credentials.txt"
}

# Display summary
display_summary() {
    section "Installation Summary"
    
    if [[ "$USE_DOCKER" == "true" ]]; then
        log "INFO" "Application deployed using Docker"
        log "INFO" "Docker Compose service: $APP_NAME-docker.service"
    else
        log "INFO" "Application deployed directly on host"
        log "INFO" "Application service: $APP_NAME.service"
        log "INFO" "Database: PostgreSQL (User: $DB_USER, Database: $DB_NAME)"
        log "INFO" "Cache: Redis (Host: $REDIS_HOST, Port: $REDIS_PORT)"
    fi
    
    log "INFO" "Application directory: $APP_HOME"
    log "INFO" "Application user: $APP_USER"
    
    if [[ "$USE_NGINX" == "true" && "$USE_DOCKER" != "true" ]]; then
        log "INFO" "Web server: Nginx"
        log "INFO" "Domain: $DOMAIN_NAME"
        
        if [[ "$USE_SSL" == "true" ]]; then
            log "INFO" "SSL: Enabled with Let's Encrypt"
        else
            log "INFO" "SSL: Not enabled"
        fi
    fi
    
    # Add Superset information to summary
    if [[ "$USE_SUPERSET" == "true" ]]; then
        log "INFO" "Analytics: Apache Superset"
        log "INFO" "Superset URL: http://${SUPERSET_DOMAIN:-"superset.$DOMAIN_NAME"}"
        log "INFO" "Superset credentials stored in: $APP_HOME/credentials/superset_credentials.txt"
        
        if [[ "$USE_DOCKER" == "true" ]]; then
            log "INFO" "Superset deployment: Docker container"
        else
            log "INFO" "Superset service: superset.service"
            log "INFO" "Superset home: $SUPERSET_HOME"
        fi
    fi
    
    log "INFO" "Backups: Daily at 2 AM (stored in $APP_HOME/backups)"
    
    # Access URLs
    if [[ "$USE_NGINX" == "true" && "$USE_DOCKER" != "true" ]]; then
        if [[ "$USE_SSL" == "true" ]]; then
            log "INFO" "Application URL: https://$DOMAIN_NAME"
        else
            log "INFO" "Application URL: http://$DOMAIN_NAME"
        fi
    else
        log "INFO" "Application URL: http://localhost:$APP_PORT"
    fi
    
    # Service management commands
    log "INFO" "Service management:"
    if [[ "$USE_DOCKER" == "true" ]]; then
        log "INFO" "Start: systemctl start $APP_NAME-docker.service"
        log "INFO" "Stop: systemctl stop $APP_NAME-docker.service"
        log "INFO" "Restart: systemctl restart $APP_NAME-docker.service"
        log "INFO" "Status: systemctl status $APP_NAME-docker.service"
    else
        log "INFO" "Start: systemctl start $APP_NAME.service"
        log "INFO" "Stop: systemctl stop $APP_NAME.service"
        log "INFO" "Restart: systemctl restart $APP_NAME.service"
        log "INFO" "Status: systemctl status $APP_NAME.service"
    fi
    
    if [[ "$USE_SUPERSET" == "true" && "$USE_DOCKER" != "true" ]]; then
        log "INFO" "Superset management:"
        log "INFO" "Start: systemctl start superset.service"
        log "INFO" "Stop: systemctl stop superset.service"
        log "INFO" "Restart: systemctl restart superset.service"
        log "INFO" "Status: systemctl status superset.service"
    fi
    
    log "INFO" "Logs: $APP_HOME/logs/"
    
    # Backup command
    log "INFO" "Manual backup: sudo -u $APP_USER $APP_HOME/scripts/backup.sh"
    
    log "SUCCESS" "Job Scraper Application has been successfully set up!"
}

# ===== Additional Helper Functions =====

# Uninstall all components
uninstall_application() {
    section "Uninstalling Job Scraper Application"
    
    log "WARNING" "This will remove all components of the Job Scraper application"
    echo -n "Are you sure you want to proceed with uninstallation? (y/n): "
    read -r confirm
    
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        log "INFO" "Uninstallation canceled"
        exit 0
    fi
    
    log "INFO" "Stopping and removing services"
    
    # Stop and remove application service
    if systemctl is-active --quiet "$APP_NAME.service" 2>/dev/null; then
        systemctl stop "$APP_NAME.service"
        systemctl disable "$APP_NAME.service"
        rm -f "/etc/systemd/system/$APP_NAME.service"
    fi
    
    # Stop and remove Docker Compose service
    if systemctl is-active --quiet "$APP_NAME-docker.service" 2>/dev/null; then
        systemctl stop "$APP_NAME-docker.service"
        systemctl disable "$APP_NAME-docker.service"
        rm -f "/etc/systemd/system/$APP_NAME-docker.service"
    fi
    
    # Stop and remove Superset service
    if systemctl is-active --quiet "superset.service" 2>/dev/null; then
        systemctl stop "superset.service"
        systemctl disable "superset.service"
        rm -f "/etc/systemd/system/superset.service"
    fi
    
    # Remove Nginx configurations
    if [ -f "/etc/nginx/sites-enabled/$APP_NAME" ]; then
        rm -f "/etc/nginx/sites-enabled/$APP_NAME"
    fi
    
    if [ -f "/etc/nginx/sites-available/$APP_NAME" ]; then
        rm -f "/etc/nginx/sites-available/$APP_NAME"
    fi
    
    if [ -f "/etc/nginx/sites-enabled/superset" ]; then
        rm -f "/etc/nginx/sites-enabled/superset"
    fi
    
    if [ -f "/etc/nginx/sites-available/superset" ]; then
        rm -f "/etc/nginx/sites-available/superset"
    fi
    
    # Reload systemd
    systemctl daemon-reload
    
    # Restart Nginx if it's running
    if systemctl is-active --quiet nginx; then
        nginx -t && systemctl restart nginx
    fi
    
    # Drop database if requested
    echo -n "Do you want to remove the database? (y/n): "
    read -r drop_db
    
    if [[ "$drop_db" == "y" || "$drop_db" == "Y" ]]; then
        if [[ "$USE_DOCKER" != "true" ]]; then
            log "INFO" "Dropping database: $DB_NAME"
            su - postgres -c "dropdb $DB_NAME" 2>/dev/null || log "WARNING" "Failed to drop database"
            
            echo -n "Remove database user as well? (y/n): "
            read -r drop_user
            
            if [[ "$drop_user" == "y" || "$drop_user" == "Y" ]]; then
                log "INFO" "Dropping database user: $DB_USER"
                su - postgres -c "dropuser $DB_USER" 2>/dev/null || log "WARNING" "Failed to drop database user"
            fi
        else
            log "INFO" "Removing Docker volumes"
            cd "$APP_HOME" && docker-compose down -v 2>/dev/null || log "WARNING" "Failed to remove Docker volumes"
        fi
    fi
    
    # Remove installation directory
    echo -n "Remove the entire application directory ($APP_HOME)? (y/n): "
    read -r remove_dir
    
    if [[ "$remove_dir" == "y" || "$remove_dir" == "Y" ]]; then
        log "INFO" "Removing application directory: $APP_HOME"
        rm -rf "$APP_HOME"
    fi
    
    # Remove application user
    echo -n "Remove the application user ($APP_USER)? (y/n): "
    read -r remove_user
    
    if [[ "$remove_user" == "y" || "$remove_user" == "Y" ]]; then
        log "INFO" "Removing application user: $APP_USER"
        userdel -r "$APP_USER" 2>/dev/null || log "WARNING" "Failed to remove user"
    fi
    
    # Remove the cloned repository if specified
    echo -n "Remove the cloned repository directory (job-scraper)? (y/n): "
    read -r remove_repo
    
    if [[ "$remove_repo" == "y" || "$remove_repo" == "Y" ]]; then
        if [ -d "../job-scraper" ]; then
            log "INFO" "Removing cloned repository: ../job-scraper"
            rm -rf "../job-scraper"
        else
            log "INFO" "Repository directory not found at ../job-scraper"
        fi
    fi
    
    log "SUCCESS" "Uninstallation completed"
    exit 0
}

# Interactive configuration
interactive_config() {
    section "Interactive Configuration"
    
    # Ask for domain name
    if [[ "$USE_NGINX" == "true" ]]; then
        echo -n "Enter the main domain name for the application [$DOMAIN_NAME]: "
        read -r domain_input
        if [ -n "$domain_input" ]; then
            DOMAIN_NAME="$domain_input"
        fi
        
        # Ask for SSL setup
        echo -n "Do you want to set up SSL with Let's Encrypt? (y/n) [${USE_SSL}]: "
        read -r ssl_input
        if [[ "$ssl_input" == "y" || "$ssl_input" == "Y" ]]; then
            USE_SSL="true"
            
            # Email for Let's Encrypt
            echo -n "Enter email address for Let's Encrypt notifications [$EMAIL]: "
            read -r email_input
            if [ -n "$email_input" ]; then
                EMAIL="$email_input"
            fi
        elif [[ "$ssl_input" == "n" || "$ssl_input" == "N" ]]; then
            USE_SSL="false"
        fi
    fi
    
    # Ask for Superset domain
    if [[ "$USE_SUPERSET" == "true" && "$USE_NGINX" == "true" ]]; then
        local default_superset_domain="superset.$DOMAIN_NAME"
        echo -n "Enter domain name for Superset [$default_superset_domain]: "
        read -r superset_domain_input
        if [ -n "$superset_domain_input" ]; then
            SUPERSET_DOMAIN="$superset_domain_input"
        else
            SUPERSET_DOMAIN="$default_superset_domain"
        fi
    fi
    
    # Ask for database passwords
    echo -n "Do you want to set custom database password? (y/n): "
    read -r db_passwd_input
    if [[ "$db_passwd_input" == "y" || "$db_passwd_input" == "Y" ]]; then
        echo -n "Enter database password: "
        read -rs DB_PASSWORD
        echo ""
    fi
    
    # Ask for Superset admin password
    if [[ "$USE_SUPERSET" == "true" ]]; then
        echo -n "Do you want to set custom Superset admin password? (y/n): "
        read -r superset_passwd_input
        if [[ "$superset_passwd_input" == "y" || "$superset_passwd_input" == "Y" ]]; then
            echo -n "Enter Superset admin password: "
            read -rs SUPERSET_PASSWORD
            echo ""
        fi
    fi
    
    log "SUCCESS" "Configuration completed"
}

# Display detailed error information
show_error_details() {
    local service_name=$1
    local log_file=$2
    
    log "ERROR" "Failed to set up $service_name"
    log "INFO" "Check the log file for more details: $log_file"
    log "INFO" "Last 10 lines of the log:"
    echo "-----------------------------------"
    if [ -f "$log_file" ]; then
        tail -n 10 "$log_file"
    else
        echo "Log file not found: $log_file"
    fi
    echo "-----------------------------------"
    log "INFO" "You can uninstall and try again with: $0 --uninstall"
}

# ===== Main Execution =====

# Check for command line flags
if [[ "$1" == "--uninstall" ]]; then
    uninstall_application
fi

# Print banner
cat << 'EOF'
   ___       _      _____                                
  |_  |     | |    /  ___|                               
    | | ___ | |__  \ `--.  ___ _ __ __ _ _ __   ___ _ __ 
    | |/ _ \| '_ \  `--. \/ __| '__/ _` | '_ \ / _ \ '__|
/\__/ / (_) | |_) |/\__/ / (__| | | (_| | |_) |  __/ |   
\____/ \___/|_.__/ \____/ \___|_|  \__,_| .__/ \___|_|   
                                        | |              
                                        |_|              
EOF
echo

log "INFO" "Starting Job Scraper Production Setup"
log "INFO" "This script will set up the Job Scraper application for production use"

# Run interactive configuration
interactive_config

# Setup main log file
MAIN_LOG_FILE="$PWD/setup_$(date +%Y%m%d%H%M%S).log"
log "INFO" "Logging installation details to $MAIN_LOG_FILE"
exec > >(tee -a "$MAIN_LOG_FILE") 2>&1

# Run installation steps
check_system_requirements || { 
    show_error_details "system requirements check" "$MAIN_LOG_FILE"
    exit 1
}

update_system_packages || {
    show_error_details "system packages update" "$MAIN_LOG_FILE"
    exit 1
}

install_dependencies || {
    show_error_details "dependencies installation" "$MAIN_LOG_FILE"
    exit 1
}

setup_application_user || {
    show_error_details "application user setup" "$MAIN_LOG_FILE"
    exit 1
}

setup_application_code || {
    show_error_details "application code setup" "$MAIN_LOG_FILE"
    exit 1
}

setup_virtualenv || {
    show_error_details "virtual environment setup" "$MAIN_LOG_FILE"
    exit 1
}

configure_application || {
    show_error_details "application configuration" "$MAIN_LOG_FILE"
    exit 1
}

setup_database || {
    show_error_details "database setup" "$MAIN_LOG_FILE"
    exit 1
}

setup_redis || {
    show_error_details "Redis setup" "$MAIN_LOG_FILE"
    exit 1
}

setup_nginx || {
    show_error_details "Nginx setup" "$MAIN_LOG_FILE"
    exit 1
}

setup_systemd_service || {
    show_error_details "systemd service setup" "$MAIN_LOG_FILE"
    exit 1
}

setup_monitoring || {
    show_error_details "monitoring setup" "$MAIN_LOG_FILE"
    exit 1
}

setup_superset || {
    show_error_details "Superset setup" "$MAIN_LOG_FILE"
    exit 1
}

setup_backups || {
    show_error_details "backups setup" "$MAIN_LOG_FILE"
    exit 1
}

setup_security || {
    show_error_details "security setup" "$MAIN_LOG_FILE"
    exit 1
}

verify_installation || {
    show_error_details "installation verification" "$MAIN_LOG_FILE"
    log "WARNING" "Installation completed with verification errors"
    log "INFO" "You can run the uninstall script to clean up: $0 --uninstall"
    display_summary
    exit 1
}

# If we got here, everything was successful
display_summary
log "SUCCESS" "Setup completed successfully!"
log "INFO" "If you need to uninstall later, run: $0 --uninstall"

exit 0 