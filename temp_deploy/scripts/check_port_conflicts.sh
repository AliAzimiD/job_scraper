#!/bin/bash
# Script to check for port conflicts before deployment

# Colors for terminal output
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
NC="\033[0m" # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Array of ports to check
PORTS=(80 443 5000 5432 6379)
PORT_NAMES=("HTTP" "HTTPS" "Flask" "PostgreSQL" "Redis")
CONFLICTS=false

log "Checking for port conflicts..."

# Check each port
for i in "${!PORTS[@]}"; do
    PORT=${PORTS[$i]}
    NAME=${PORT_NAMES[$i]}
    
    # Check if port is in use
    if netstat -tuln | grep -q ":$PORT "; then
        CONFLICTS=true
        error "Port $PORT ($NAME) is already in use."
        PROCESS=$(lsof -i :$PORT | grep LISTEN)
        if [ -n "$PROCESS" ]; then
            warn "Process using port $PORT: $PROCESS"
        fi
    else
        log "Port $PORT ($NAME) is available."
    fi
done

# If conflicts were found, offer resolution options
if [ "$CONFLICTS" = true ]; then
    echo ""
    warn "Port conflicts were detected. You have the following options:"
    echo "1. Stop the conflicting services:"
    echo "   - For system services: systemctl stop SERVICE_NAME"
    echo "   - For Docker containers: docker stop CONTAINER_ID"
    echo ""
    echo "2. Change the port mapping in docker-compose.yml:"
    echo "   - For example, change '80:80' to '8080:80'"
    echo ""
    echo "3. Continue anyway (not recommended if the same ports are needed)"
    echo ""
    read -p "Do you want to continue with the deployment? (y/N): " CONTINUE
    
    if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
        error "Deployment aborted due to port conflicts."
        exit 1
    else
        warn "Continuing deployment despite port conflicts..."
    fi
else
    log "No port conflicts detected. Proceeding with deployment."
fi

exit 0 