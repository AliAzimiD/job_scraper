#!/bin/bash

# Constants
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m"

# Function to print colorful messages
log() {
  local color=$1
  local message=$2
  echo -e "${color}${message}${NC}"
}

# Check if user is root
if [ "$(id -u)" != "0" ]; then
  log $RED "This script must be run as root"
  exit 1
fi

# Check if Docker is installed
if ! command -v docker >/dev/null 2>&1; then
  log $YELLOW "Docker not found. Installing..."
  curl -fsSL https://get.docker.com -o get-docker.sh
  sh get-docker.sh
  log $GREEN "Docker installed successfully"
fi

# Check if Docker Compose is installed
if ! command -v docker-compose >/dev/null 2>&1; then
  log $YELLOW "Docker Compose not found. Installing..."
  curl -L "https://github.com/docker/compose/releases/download/v2.23.3/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  log $GREEN "Docker Compose installed successfully"
fi

# Create required directories
log $YELLOW "Creating required directories..."
mkdir -p data/certbot/conf
mkdir -p data/certbot/www
mkdir -p static
mkdir -p logs
mkdir -p uploads
mkdir -p init-db

# Copy new docker-compose file
log $YELLOW "Setting up Docker Compose configuration..."
cp docker-compose-new.yml docker-compose.yml
chmod 644 docker-compose.yml

# Stop existing containers
log $YELLOW "Stopping any existing containers..."
docker-compose down || true

# Start the containers
log $GREEN "Starting the application with Docker Compose..."
docker-compose up -d

# Wait for services to be ready
log $YELLOW "Waiting for services to start up..."
sleep 10

# Show status
log $GREEN "Docker containers status:"
docker-compose ps

log $GREEN "Application deployed successfully!"
log $GREEN "You can access the application at http://upgrade4u.online"
log $GREEN "You can access Superset at http://superset.upgrade4u.online"
