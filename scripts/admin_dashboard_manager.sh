#!/bin/bash
# Admin Dashboard Manager Script
# This script provides commands to manage the Job Scraper Admin Dashboard

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

# Configuration
DEFAULT_PORT=8081
PID_FILE="${PROJECT_ROOT}/admin_dashboard.pid"
LOG_FILE="${PROJECT_ROOT}/logs/admin_dashboard.log"

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

# Check if the dashboard is running
is_running() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null; then
            return 0  # Running
        else
            rm -f "$PID_FILE"  # Remove stale PID file
        fi
    fi
    return 1  # Not running
}

# Get the port the dashboard is running on
get_port() {
    if is_running; then
        PID=$(cat "$PID_FILE")
        PORT=$(netstat -tlnp 2>/dev/null | grep "$PID" | grep -oP ':::\K[0-9]+' | head -1)
        if [ -z "$PORT" ]; then
            PORT=$(netstat -tlnp 2>/dev/null | grep "$PID" | grep -oP '0.0.0.0:\K[0-9]+' | head -1)
        fi
        echo "$PORT"
    else
        echo "$DEFAULT_PORT"
    fi
}

# Start the dashboard
start_dashboard() {
    local port=${1:-$DEFAULT_PORT}
    
    if is_running; then
        warning "Admin dashboard is already running."
        status_dashboard
        return 0
    fi
    
    section "Starting Admin Dashboard"
    
    # Ensure directories exist
    mkdir -p "$(dirname "$LOG_FILE")"
    
    # Start the dashboard
    echo "Starting dashboard on port $port..."
    nohup python3 run_admin_dashboard.py --port "$port" > "$LOG_FILE" 2>&1 &
    echo $! > "$PID_FILE"
    
    # Wait a moment for it to start
    sleep 3
    
    if is_running; then
        success "Admin dashboard started successfully!"
        status_dashboard
    else
        error "Failed to start admin dashboard. Check logs for details."
        tail -n 20 "$LOG_FILE"
        return 1
    fi
}

# Stop the dashboard
stop_dashboard() {
    if ! is_running; then
        warning "Admin dashboard is not running."
        return 0
    fi
    
    section "Stopping Admin Dashboard"
    
    PID=$(cat "$PID_FILE")
    echo "Stopping dashboard process $PID..."
    
    kill "$PID" 2>/dev/null || true
    
    # Wait for it to stop
    for i in {1..10}; do
        if ! ps -p "$PID" > /dev/null; then
            break
        fi
        echo "Waiting for dashboard to stop..."
        sleep 1
    done
    
    # If it's still running, force kill
    if ps -p "$PID" > /dev/null; then
        warning "Dashboard did not stop gracefully. Forcing termination..."
        kill -9 "$PID" 2>/dev/null || true
    fi
    
    # Clean up PID file
    rm -f "$PID_FILE"
    
    success "Admin dashboard stopped successfully!"
}

# Restart the dashboard
restart_dashboard() {
    local port=${1:-$(get_port)}
    
    section "Restarting Admin Dashboard"
    
    stop_dashboard
    sleep 2
    start_dashboard "$port"
}

# Check dashboard status
status_dashboard() {
    section "Admin Dashboard Status"
    
    if is_running; then
        PID=$(cat "$PID_FILE")
        PORT=$(get_port)
        success "Admin dashboard is running"
        echo "Process ID: $PID"
        echo "Port: $PORT"
        echo "URL: http://localhost:$PORT/admin"
        echo "Log file: $LOG_FILE"
    else
        warning "Admin dashboard is not running"
    fi
}

# Show dashboard logs
show_logs() {
    local lines=${1:-50}
    
    section "Admin Dashboard Logs (last $lines lines)"
    
    if [ -f "$LOG_FILE" ]; then
        tail -n "$lines" "$LOG_FILE"
    else
        error "Log file not found: $LOG_FILE"
    fi
}

# Check if port is available
check_port() {
    local port=${1:-$DEFAULT_PORT}
    
    if netstat -tuln | grep -q ":$port "; then
        echo "Port $port is in use"
        return 1
    else
        echo "Port $port is available"
        return 0
    fi
}

# Print usage
usage() {
    echo -e "${BLUE}Job Scraper Admin Dashboard Manager${NC}"
    echo
    echo "Usage: $0 COMMAND [OPTIONS]"
    echo
    echo "Commands:"
    echo "  start [port]     Start the admin dashboard (default port: $DEFAULT_PORT)"
    echo "  stop             Stop the admin dashboard"
    echo "  restart [port]   Restart the admin dashboard"
    echo "  status           Check the status of the admin dashboard"
    echo "  logs [lines]     Show the last N lines of logs (default: 50)"
    echo "  check-port [port] Check if a port is available (default: $DEFAULT_PORT)"
    echo "  help             Show this help message"
    echo
    echo "Examples:"
    echo "  $0 start         # Start the dashboard on default port"
    echo "  $0 start 8090    # Start the dashboard on port 8090"
    echo "  $0 logs 100      # Show the last 100 log lines"
}

# Main function
main() {
    # Create required directories
    mkdir -p "${PROJECT_ROOT}/logs"
    
    # Process command
    if [ $# -eq 0 ]; then
        usage
        exit 1
    fi
    
    command="$1"
    shift
    
    case "$command" in
        start)
            port=${1:-$DEFAULT_PORT}
            start_dashboard "$port"
            ;;
        stop)
            stop_dashboard
            ;;
        restart)
            port=${1:-$(get_port)}
            restart_dashboard "$port"
            ;;
        status)
            status_dashboard
            ;;
        logs)
            lines=${1:-50}
            show_logs "$lines"
            ;;
        check-port)
            port=${1:-$DEFAULT_PORT}
            check_port "$port"
            ;;
        help|--help|-h)
            usage
            ;;
        *)
            error "Unknown command: $command"
            usage
            exit 1
            ;;
    esac
}

# Execute main function
main "$@" 