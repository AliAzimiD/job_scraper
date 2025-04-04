#!/bin/bash

# Script to run the Admin Dashboard using Docker Compose
set -e

# Get script directory for proper path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "${PROJECT_ROOT}"  # Ensure we're in the project root

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Print a section header
section() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

# Print a success message
success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Print a warning
warning() {
    echo -e "${YELLOW}! $1${NC}"
}

# Print an error
error() {
    echo -e "${RED}✗ $1${NC}"
}

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    error "Docker is not installed. Please install Docker first."
    exit 1
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &> /dev/null; then
    error "Docker Compose is not installed. Please install Docker Compose first."
    exit 1
fi

# Check if the Docker Compose file exists
DOCKER_COMPOSE_FILE="${PROJECT_ROOT}/docker/docker-compose.admin.yml"
if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
    error "Docker Compose file not found: $DOCKER_COMPOSE_FILE"
    exit 1
fi

# Check if the secrets directory exists
SECRETS_DIR="${PROJECT_ROOT}/secrets"
if [ ! -d "$SECRETS_DIR" ]; then
    warning "Secrets directory not found: $SECRETS_DIR. Creating it..."
    mkdir -p "$SECRETS_DIR"
fi

# Check if the database password file exists
DB_PASSWORD_FILE="${SECRETS_DIR}/db_password.txt"
if [ ! -f "$DB_PASSWORD_FILE" ]; then
    warning "Database password file not found: $DB_PASSWORD_FILE. Creating it with a random password..."
    # Generate a random password
    PASSWORD=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | fold -w 16 | head -n 1)
    echo "$PASSWORD" > "$DB_PASSWORD_FILE"
    success "Created database password file with a random password."
fi

# Create required directories
section "Creating required directories"
mkdir -p "${PROJECT_ROOT}/logs"
mkdir -p "${PROJECT_ROOT}/public/admin"
success "Created required directories"

# Check if the admin UI is set up
if [ ! -f "${PROJECT_ROOT}/public/admin/index.html" ]; then
    warning "Admin UI not set up. Running setup script..."
    if [ -f "${PROJECT_ROOT}/scripts/setup_admin.sh" ]; then
        bash "${PROJECT_ROOT}/scripts/setup_admin.sh"
        success "Admin UI setup complete"
    else
        error "Admin UI setup script not found: ${PROJECT_ROOT}/scripts/setup_admin.sh"
        exit 1
    fi
fi

# Start the services
section "Starting Admin Dashboard in Docker"
echo "This will start the Admin Dashboard and a PostgreSQL database."
echo "The Admin Dashboard will be available at: http://localhost:8081/admin"
echo "Press Ctrl+C to stop the services."
echo ""

# Start the services
docker-compose -f "$DOCKER_COMPOSE_FILE" up --build

# Script will end when the user presses Ctrl+C 