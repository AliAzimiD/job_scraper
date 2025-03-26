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
    
    local base_packages="curl wget git software-properties-common apt-transport-https ca-certificates gnupg lsb-release unzip build-essential libssl-dev libffi-dev python3-dev python3-pip python3-venv"
    local postgres_packages="postgresql-$POSTGRES_VERSION postgresql-contrib postgresql-client-$POSTGRES_VERSION"
    local nginx_packages="nginx certbot python3-certbot-nginx"
    local redis_packages="redis-server"
    local monitoring_packages="prometheus-node-exporter"
    
    log "INFO" "Installing base packages"
    apt-get install -y -qq $base_packages || {
        log "ERROR" "Failed to install base packages"
        exit 1
    }
    
    # Check if Docker should be installed
    if [[ "$USE_DOCKER" == "true" ]]; then
        log "INFO" "Installing Docker and Docker Compose"
        install_docker
    else
        # Install PostgreSQL
        log "INFO" "Installing PostgreSQL $POSTGRES_VERSION"
        apt-get install -y -qq $postgres_packages || {
            log "ERROR" "Failed to install PostgreSQL"
            exit 1
        }
        
        # Install Redis
        log "INFO" "Installing Redis"
        apt-get install -y -qq $redis_packages || {
            log "ERROR" "Failed to install Redis"
            exit 1
        }
        
        # Install Nginx if needed
        if [[ "$USE_NGINX" == "true" ]]; then
            log "INFO" "Installing Nginx and Certbot"
            apt-get install -y -qq $nginx_packages || {
                log "ERROR" "Failed to install Nginx and Certbot"
                exit 1
            }
        fi
    fi
    
    # Install monitoring tools
    log "INFO" "Installing monitoring tools"
    apt-get install -y -qq $monitoring_packages || {
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
    mkdir -p "$APP_HOME/scripts"
    
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
    
    # Install gunicorn for production
    su - "$APP_USER" -c "cd $APP_HOME && source venv/bin/activate && pip install gunicorn" || {
        log "ERROR" "Failed to install Gunicorn"
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
    
    # Initialize database tables
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
    
    log "INFO" "Logs: $APP_HOME/logs/"
    
    # Backup command
    log "INFO" "Manual backup: sudo -u $APP_USER $APP_HOME/scripts/backup.sh"
    
    log "SUCCESS" "Job Scraper Application has been successfully set up!"
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
        setup_ssl_for_domain "superset.$DOMAIN_NAME"
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

# ===== Main Execution =====

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

# Run installation steps
check_system_requirements
update_system_packages
install_dependencies
setup_application_user
setup_application_code
setup_virtualenv
configure_application
setup_database
setup_redis
setup_nginx
setup_systemd_service
setup_monitoring
setup_backups
setup_security
verify_installation
display_summary

log "INFO" "Setup completed!"
log "INFO" "Please save the Installation Summary for future reference"

exit 0 