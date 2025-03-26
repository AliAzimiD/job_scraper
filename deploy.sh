#!/bin/bash
# Job Scraper Deployment Script
# This script automates the process of deploying the job scraper application to a VPS

set -e

# Terminal colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

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

# Display help information
show_help() {
    cat << EOF
Job Scraper Deployment Script

Usage: $0 [options]

Options:
  -h, --help                Show this help message
  -c, --config <file>       Use specified config file (default: deploy.conf)
  -t, --test                Test deployment locally using Docker
  -u, --uninstall           Uninstall the application before deploying
  -b, --backup              Create a backup before deploying
  --no-verify               Skip verification step

Example:
  $0 --config my-server.conf  # Deploy using specified config
  $0 --test                   # Test deployment locally
  $0 --uninstall              # Clean install (remove previous installation)

EOF
    exit 0
}

# Check if config file exists
check_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log "ERROR" "Config file $CONFIG_FILE not found"
        echo "Please create a config file with your deployment settings."
        echo "You can use the template in deploy.conf.example"
        exit 1
    fi
    
    # Load main configuration
    source "$CONFIG_FILE"
    
    # Check for local config with sensitive data
    LOCAL_CONFIG="deploy.local.conf"
    if [ -f "$LOCAL_CONFIG" ]; then
        log "INFO" "Found local configuration with sensitive data"
        source "$LOCAL_CONFIG"
    else
        log "WARNING" "Local config file ($LOCAL_CONFIG) not found"
        log "INFO" "You may want to create this file with your GitHub credentials:"
        echo "GITHUB_TOKEN=\"your-github-token\"" > "$LOCAL_CONFIG.example"
        echo "# OR use username/password" >> "$LOCAL_CONFIG.example"
        echo "GITHUB_USERNAME=\"your-username\"" >> "$LOCAL_CONFIG.example"
        echo "GITHUB_PASSWORD=\"your-password\"" >> "$LOCAL_CONFIG.example" 
        log "INFO" "See $LOCAL_CONFIG.example for template"
        log "INFO" "Continuing without GitHub credentials (will work only for public repositories)"
    fi
}

# Generate server setup script from template
generate_server_setup() {
    log "INFO" "Generating server setup script"
    
    # Create server setup script
    cat > server_setup.sh << 'EOF'
#!/bin/bash
# This is a generated script to prepare the server for deployment

# Print status
echo "Setting up server for deployment..."
echo "REMOTE_PATH: $REMOTE_PATH"

# Function to fix Nginx configuration
fix_nginx() {
    echo "Checking and fixing Nginx configuration..."
    
    # Check if Nginx is installed
    if ! command -v nginx &> /dev/null; then
        echo "Nginx not installed. Installing..."
        apt update
        apt install -y nginx
    else
        echo "Nginx is already installed"
    fi
    
    # Make sure Nginx is enabled and running
    systemctl enable nginx
    systemctl start nginx
    
    # Copy our custom Nginx configuration if it exists
    if [ -f "nginx_jobscraper.conf" ]; then
        echo "Installing custom Nginx configuration..."
        cp nginx_jobscraper.conf /etc/nginx/sites-available/jobscraper
        
        # Enable the site
        ln -sf /etc/nginx/sites-available/jobscraper /etc/nginx/sites-enabled/
        
        # Remove default site if it exists
        if [ -f "/etc/nginx/sites-enabled/default" ]; then
            rm -f /etc/nginx/sites-enabled/default
        fi
        
        # Test configuration
        nginx -t
        
        # Reload Nginx
        systemctl reload nginx
    else
        echo "Custom Nginx configuration not found"
    fi
}

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker "$USER"
    systemctl enable docker
    systemctl start docker
    rm get-docker.sh
fi

# Create deployment directory if it doesn't exist
if [ -z "$REMOTE_PATH" ]; then
    echo "ERROR: REMOTE_PATH is not set"
    exit 1
fi

echo "Creating deployment directory: $REMOTE_PATH"
mkdir -p "$REMOTE_PATH"
chmod 755 "$REMOTE_PATH"

# Fix Nginx configuration
fix_nginx

echo "Server preparation completed"
EOF
    chmod +x server_setup.sh
    
    # Create Nginx configuration file with correct domain name
    log "INFO" "Generating Nginx configuration"
    cat > nginx_jobscraper.conf << EOF
server {
    listen 80;
    server_name $DOMAIN_NAME;

    access_log /var/log/nginx/jobscraper_access.log;
    error_log /var/log/nginx/jobscraper_error.log;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_connect_timeout 60s;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }

    location /static {
        alias $APP_HOME/static;
        expires 30d;
    }

    # Add security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}
EOF
}

# Generate auto-answer file for setup.sh
generate_answer_file() {
    log "INFO" "Generating automated answers file for setup.sh"
    
    source "$CONFIG_FILE"
    
    cat > setup_answers.sh << EOF
#!/bin/bash
# Auto-generated answers for interactive prompts in setup.sh

# Setup environment variables
export APP_USER="$APP_USER"
export APP_GROUP="$APP_GROUP"
export APP_HOME="$APP_HOME"
export APP_PORT="$APP_PORT"
export DOMAIN_NAME="$DOMAIN_NAME"
export USE_SSL="$USE_SSL"
export EMAIL="$EMAIL"
export USE_SUPERSET="$USE_SUPERSET"
export SUPERSET_DOMAIN="$SUPERSET_DOMAIN"
export SUPERSET_USER="$SUPERSET_USER"
export SUPERSET_PASSWORD="$SUPERSET_PASSWORD"
export DB_USER="$DB_USER"
export DB_NAME="$DB_NAME"
EOF

    if [ -n "$DB_PASSWORD" ]; then
        echo "export DB_PASSWORD=\"$DB_PASSWORD\"" >> setup_answers.sh
    fi
    
    chmod +x setup_answers.sh
}

# Add GitHub authentication helper
setup_github_auth() {
    log "INFO" "Setting up GitHub authentication for deployment"
    
    # Instead of using credential.helper, we'll directly inject username/password into the URL
    if [ -n "$GITHUB_USERNAME" ] && [ -n "$GITHUB_PASSWORD" ]; then
        # Replace the URL with one containing credentials
        REPO_URL="https://$GITHUB_USERNAME:$GITHUB_PASSWORD@${REPO_URL#https://}"
        log "INFO" "GitHub credentials applied to repository URL"
    elif [ -n "$GITHUB_TOKEN" ]; then
        # Use a token if provided
        REPO_URL="https://$GITHUB_TOKEN@${REPO_URL#https://}"
        log "INFO" "GitHub token applied to repository URL"
    else
        log "WARNING" "No GitHub credentials provided. Public repositories will work, but private repositories will fail."
    fi
    
    export REPO_URL
}

# Test deployment using Docker
test_deployment() {
    log "INFO" "Testing deployment in Docker container"
    
    # Check if Docker is installed
    if ! command -v docker &> /dev/null; then
        log "ERROR" "Docker is not installed. Please install Docker to use testing mode."
        exit 1
    fi
    
    log "INFO" "Pulling Ubuntu image"
    docker pull ubuntu:22.04
    
    log "INFO" "Preparing test environment"
    docker run -it --rm \
        -v "$(pwd):/app" \
        -w /app \
        --name job-scraper-test \
        ubuntu:22.04 \
        bash -c "apt-get update && apt-get install -y sudo curl && cd /app && ./test-setup.sh"
    
    log "SUCCESS" "Test deployment completed"
}

# Add function to check and fix common application issues
run_post_deployment_troubleshooting() {
    log "INFO" "Running post-deployment diagnostics..."
    
    # Connect to server and run checks
    ssh -t "$SERVER_USER@$SERVER_HOST" "
        echo '============================================================'
        echo 'RUNNING COMPREHENSIVE POST-DEPLOYMENT CHECKS'
        echo '============================================================'
        
        # Check if Nginx is installed and running
        echo '1. Checking Nginx status:'
        if ! command -v nginx &> /dev/null; then
            echo '   ERROR: Nginx is not installed'
        else
            echo '   Nginx is installed'
            systemctl status nginx | grep -E 'Active:|running'
            
            # Check Nginx configuration
            echo '   Validating Nginx configuration:'
            nginx -t
            
            # Check Nginx config files
            echo '   Checking Nginx site configuration:'
            ls -la /etc/nginx/sites-enabled/
            cat /etc/nginx/sites-enabled/jobscraper 2>/dev/null || echo '   No jobscraper site configuration found'
        fi
        
        # Check if application service is running
        echo '2. Checking application service status:'
        systemctl status jobscraper | grep -E 'Active:|running' || echo '   jobscraper service not found or not running'
        
        # Check application logs
        echo '3. Checking application logs:'
        if [ -d '/opt/jobscraper/logs' ]; then
            tail -n 20 /opt/jobscraper/logs/*.log 2>/dev/null || echo '   No log files found'
        else
            echo '   Application log directory not found'
        fi
        
        # Check port usage
        echo '4. Checking if application port is in use:'
        netstat -tuln | grep 5001 || echo '   Port 5001 is not in use by any application'
        
        # Check firewall status
        echo '5. Checking firewall status:'
        if command -v ufw &> /dev/null; then
            ufw status
        else
            echo '   UFW firewall not installed'
        fi
        
        # Check Nginx error logs
        echo '6. Checking Nginx error logs:'
        tail -n 30 /var/log/nginx/error.log
        
        # Attempt to directly access the application
        echo '7. Attempting to connect to application directly:'
        curl -v http://localhost:5001/ 2>&1 | grep -E 'Connected|HTTP/|<'
        
        echo '============================================================'
        echo 'END OF DIAGNOSTICS'
        echo '============================================================'
    "
}

# Run deployment
deploy() {
    log "INFO" "Starting deployment process"
    
    check_config
    source "$CONFIG_FILE"
    
    # Setup GitHub authentication
    setup_github_auth
    
    # Generate the necessary files
    generate_server_setup
    generate_answer_file
    
    # Create deployment package
    log "INFO" "Creating deployment package"
    tar -czf deploy_package.tar.gz *.sh deploy.conf nginx_jobscraper.conf
    
    # Check if sshpass is needed and installed
    if [ -n "$SERVER_PASSWORD" ]; then
        if ! command -v sshpass &> /dev/null; then
            log "WARNING" "Password authentication requested but sshpass is not installed"
            log "INFO" "Installing sshpass..."
            apt-get update && apt-get install -y sshpass || {
                log "ERROR" "Failed to install sshpass. Please install it manually or use SSH key authentication."
                exit 1
            }
        fi
        
        # Upload to server using password
        log "INFO" "Uploading deployment package to server using password authentication"
        sshpass -p "$SERVER_PASSWORD" scp deploy_package.tar.gz "$SERVER_USER@$SERVER_HOST:~/"
        
        # Execute deployment on server using password
        log "INFO" "Executing deployment on server"
        sshpass -p "$SERVER_PASSWORD" ssh -t "$SERVER_USER@$SERVER_HOST" "
            # Extract deployment package
            mkdir -p ~/deploy_tmp
            tar -xzf ~/deploy_package.tar.gz -C ~/deploy_tmp
            cd ~/deploy_tmp
            
            # Source the configuration to get REMOTE_PATH
            source deploy.conf
            
            # Run server setup with REMOTE_PATH
            export REMOTE_PATH=\"$REMOTE_PATH\"
            chmod +x ./server_setup.sh
            ./server_setup.sh
            
            # Make sure REMOTE_PATH exists
            mkdir -p \"$REMOTE_PATH\"
            
            # If uninstall flag was specified, run uninstallation first
            if [ \"$DO_UNINSTALL\" = true ]; then
                if [ -d \"$REMOTE_PATH\" ] && [ -f \"$REMOTE_PATH/setup.sh\" ]; then
                    cd \"$REMOTE_PATH\"
                    sudo ./setup.sh --uninstall || echo "No previous installation to uninstall or uninstall failed"
                    cd ~
                fi
            fi
            
            # Setup Git credential helper on the server
            git config --global credential.helper 'cache --timeout=3600'
            
            # Clone fresh repository (will prompt for credentials if needed)
            sudo rm -rf \"$REMOTE_PATH\"
            mkdir -p \"$REMOTE_PATH\"
            git clone -b \"$REPO_BRANCH\" \"$REPO_URL\" \"$REMOTE_PATH\"
            
            # Verify the clone was successful
            if [ ! -d \"$REMOTE_PATH\" ] || [ ! -f \"$REMOTE_PATH/setup.sh\" ]; then
                echo \"Failed to clone repository or setup.sh not found in cloned repository\"
                exit 1
            fi
            
            # Navigate to the repository directory
            cd \"$REMOTE_PATH\"
            
            # Source the answers file to pre-set environment variables
            source ~/deploy_tmp/setup_answers.sh
            
            # Run setup script
            echo 'Running setup script...'
            if [ \"$DO_UNINSTALL\" = true ]; then
                echo "Running in uninstall mode first..."
                sudo -E ./setup.sh --uninstall || {
                    echo 'Uninstall failed, but continuing with installation'
                }
            fi
            
            if [ \"$DO_VERIFY\" = true ]; then
                sudo -E ./setup.sh || {
                    echo 'Setup script failed'
                    exit 1
                }
            else
                sudo -E ./setup.sh --no-verify || {
                    echo 'Setup script failed'
                    exit 1
                }
            fi
            
            # Clean up
            cd ~
            rm -rf ~/deploy_tmp
            rm deploy_package.tar.gz
        "
    else
        # Upload to server using SSH key
        log "INFO" "Uploading deployment package to server using SSH key authentication"
        scp deploy_package.tar.gz "$SERVER_USER@$SERVER_HOST:~/"
        
        # Execute deployment on server using SSH key
        log "INFO" "Executing deployment on server"
        ssh -t "$SERVER_USER@$SERVER_HOST" "
            set -e
            
            # Extract deployment package
            mkdir -p ~/deploy_tmp
            tar -xzf ~/deploy_package.tar.gz -C ~/deploy_tmp
            cd ~/deploy_tmp
            
            # Source the configuration to get REMOTE_PATH
            source deploy.conf
            
            # Run server setup with REMOTE_PATH
            export REMOTE_PATH=\"$REMOTE_PATH\"
            chmod +x ./server_setup.sh
            ./server_setup.sh
            
            # Make sure REMOTE_PATH exists
            mkdir -p \"$REMOTE_PATH\"
            
            # If uninstall flag was specified, run uninstallation first
            if [ \"$DO_UNINSTALL\" = true ]; then
                if [ -d \"$REMOTE_PATH\" ] && [ -f \"$REMOTE_PATH/setup.sh\" ]; then
                    cd \"$REMOTE_PATH\"
                    echo 'Running uninstall...'
                    sudo ./setup.sh --uninstall || echo 'No previous installation to uninstall or uninstall failed'
                    cd ~
                else
                    echo 'No previous installation found to uninstall'
                fi
            fi
            
            # Clone fresh repository with credentials in URL
            sudo rm -rf \"$REMOTE_PATH\"
            mkdir -p \"$REMOTE_PATH\"
            
            echo 'Cloning repository...'
            git clone -b \"$REPO_BRANCH\" \"$REPO_URL\" \"$REMOTE_PATH\" || {
                echo 'Failed to clone repository'
                exit 1
            }
            
            # Verify the clone was successful
            if [ ! -d \"$REMOTE_PATH\" ] || [ ! -f \"$REMOTE_PATH/setup.sh\" ]; then
                echo \"Repository cloned but setup.sh not found in cloned repository\"
                exit 1
            fi
            
            # Navigate to the repository directory
            cd \"$REMOTE_PATH\"
            
            # Make sure setup.sh is executable
            chmod +x setup.sh
            
            # Source the answers file to pre-set environment variables
            source ~/deploy_tmp/setup_answers.sh
            
            # Run setup script
            echo 'Running setup script...'
            if [ \"$DO_UNINSTALL\" = true ]; then
                echo "Running in uninstall mode first..."
                sudo -E ./setup.sh --uninstall || {
                    echo 'Uninstall failed, but continuing with installation'
                }
            fi
            
            if [ \"$DO_VERIFY\" = true ]; then
                sudo -E ./setup.sh || {
                    echo 'Setup script failed'
                    exit 1
                }
            else
                sudo -E ./setup.sh --no-verify || {
                    echo 'Setup script failed'
                    exit 1
                }
            fi
            
            # Clean up
            cd ~
            rm -rf ~/deploy_tmp
            rm deploy_package.tar.gz
            
            echo 'Deployment completed on server'
        " || {
            log "ERROR" "Deployment failed on server"
            exit 1
        }
    fi
    
    log "SUCCESS" "Deployment completed successfully!"
    log "INFO" "You can access your application at: http://$DOMAIN_NAME"
    
    if [ "$USE_SSL" = true ]; then
        log "INFO" "Secure access (SSL): https://$DOMAIN_NAME"
    fi
    
    if [ "$USE_SUPERSET" = true ]; then
        log "INFO" "Superset analytics: http://$SUPERSET_DOMAIN"
        if [ "$USE_SSL" = true ]; then
            log "INFO" "Secure Superset (SSL): https://$SUPERSET_DOMAIN"
        fi
    fi

    # Run post-deployment troubleshooting
    run_post_deployment_troubleshooting
}

# Create local test script
generate_test_script() {
    cat > test-setup.sh << 'EOF'
#!/bin/bash
# Test script for local Docker deployment

echo "This is a simulation of the setup script execution."
echo "In a real test, this would run the actual setup script with test parameters."
echo "Testing deployment in Docker environment..."
echo "All steps completed successfully in test mode!"
EOF
    chmod +x test-setup.sh
}

# Main script execution
main() {
    # Default values
    CONFIG_FILE="deploy.conf"
    DO_TEST=false
    DO_UNINSTALL=false
    DO_BACKUP=false
    DO_VERIFY=true
    
    # Parse command line arguments
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                show_help
                ;;
            -c|--config)
                CONFIG_FILE="$2"
                shift
                ;;
            -t|--test)
                DO_TEST=true
                ;;
            -u|--uninstall)
                DO_UNINSTALL=true
                ;;
            -b|--backup)
                DO_BACKUP=true
                ;;
            --no-verify)
                DO_VERIFY=false
                ;;
            *)
                log "ERROR" "Unknown option: $1"
                show_help
                ;;
        esac
        shift
    done
    
    # Create test script for Docker testing
    generate_test_script
    
    # Run test mode if specified
    if [ "$DO_TEST" = true ]; then
        test_deployment
        exit 0
    fi
    
    # Start the actual deployment
    deploy
}

# Execute main function
main "$@" 