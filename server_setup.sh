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
