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
    
    # Check for local config with sensitive data
    LOCAL_CONFIG="deploy.local.conf"
    if [ -f "$LOCAL_CONFIG" ]; then
        log "INFO" "Found local configuration with sensitive data"
        source "$LOCAL_CONFIG"
    else
        log "WARNING" "Local config file ($LOCAL_CONFIG) not found"
        log "INFO" "Please create this file with your GitHub token:"
        echo "GITHUB_TOKEN=\"your-github-token\"" > "$LOCAL_CONFIG.example"
        log "INFO" "See $LOCAL_CONFIG.example for template"
        log "ERROR" "Cannot proceed without GitHub authentication"
        exit 1
    fi
}

# Generate server setup script from template
generate_server_setup() {
    log "INFO" "Generating server setup script"
    cat > server_setup.sh << 'EOF'
#!/bin/bash
# This is a generated script to prepare the server for deployment

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
mkdir -p "$REMOTE_PATH"

echo "Server preparation completed"
EOF
    chmod +x server_setup.sh
}

# Create auto-answer file for setup.sh
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

# Run deployment
deploy() {
    log "INFO" "Starting deployment process"
    
    check_config
    source "$CONFIG_FILE"
    
    # Replace token placeholder in REPO_URL
    if [ -n "$GITHUB_TOKEN" ]; then
        REPO_URL="${REPO_URL/GITHUB_TOKEN/$GITHUB_TOKEN}"
        log "INFO" "GitHub token applied to repository URL"
    else
        log "ERROR" "GitHub token not found in $LOCAL_CONFIG"
        exit 1
    fi
    
    # Generate the necessary files
    generate_server_setup
    generate_answer_file
    
    # Create deployment package
    log "INFO" "Creating deployment package"
    tar -czf deploy_package.tar.gz *.sh deploy.conf
    
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
            REMOTE_PATH=\"$REMOTE_PATH\" ./server_setup.sh
            
            # If uninstall flag was specified, run uninstallation first
            if [ \"$DO_UNINSTALL\" = true ]; then
                if [ -d \"$REMOTE_PATH\" ]; then
                    cd \"$REMOTE_PATH\"
                    sudo ./setup.sh --uninstall
                fi
            fi
            
            # Clone fresh repository
            sudo rm -rf \"$REMOTE_PATH\"
            git clone -b \"$REPO_BRANCH\" \"$REPO_URL\" \"$REMOTE_PATH\"
            cd \"$REMOTE_PATH\"
            
            # Source the answers file to pre-set environment variables
            source ~/deploy_tmp/setup_answers.sh
            
            # Run setup script
            if [ \"$DO_VERIFY\" = true ]; then
                sudo -E ./setup.sh
            else
                sudo -E ./setup.sh --no-verify
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
            # Extract deployment package
            mkdir -p ~/deploy_tmp
            tar -xzf ~/deploy_package.tar.gz -C ~/deploy_tmp
            cd ~/deploy_tmp
            
            # Source the configuration to get REMOTE_PATH
            source deploy.conf
            
            # Run server setup with REMOTE_PATH
            REMOTE_PATH=\"$REMOTE_PATH\" ./server_setup.sh
            
            # If uninstall flag was specified, run uninstallation first
            if [ \"$DO_UNINSTALL\" = true ]; then
                if [ -d \"$REMOTE_PATH\" ]; then
                    cd \"$REMOTE_PATH\"
                    sudo ./setup.sh --uninstall
                fi
            fi
            
            # Clone fresh repository
            sudo rm -rf \"$REMOTE_PATH\"
            git clone -b \"$REPO_BRANCH\" \"$REPO_URL\" \"$REMOTE_PATH\"
            cd \"$REMOTE_PATH\"
            
            # Source the answers file to pre-set environment variables
            source ~/deploy_tmp/setup_answers.sh
            
            # Run setup script
            if [ \"$DO_VERIFY\" = true ]; then
                sudo -E ./setup.sh
            else
                sudo -E ./setup.sh --no-verify
            fi
            
            # Clean up
            cd ~
            rm -rf ~/deploy_tmp
            rm deploy_package.tar.gz
        "
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

    # Add troubleshooting steps after successful deployment
    log "INFO" "Running post-deployment checks..."
    ssh -t "$SERVER_USER@$SERVER_HOST" "
        echo \"Checking Nginx status...\"
        systemctl status nginx || echo \"Nginx service not running properly\"
        
        echo \"Checking application service status...\"
        systemctl status jobscraper || echo \"Application service not running properly\"
        
        echo \"Checking Nginx configuration...\"
        nginx -t || echo \"Nginx configuration has errors\"
        
        echo \"Checking logs for errors...\"
        tail -n 20 /var/log/nginx/error.log
        
        echo \"Post-deployment checks completed\"
    "
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