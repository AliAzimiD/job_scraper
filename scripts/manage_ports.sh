#!/bin/bash
# Script to manage processes using specific ports for the Job Scraper application
# Usage: ./manage_ports.sh [check|kill|free] [port_number]

set -e

# Default port
DEFAULT_PORT=8081

# Functions
check_port() {
    local port=$1
    echo "Checking port $port..."
    netstat -tulpn | grep -w "$port" || echo "Port $port is free"
}

kill_port_process() {
    local port=$1
    echo "Finding process using port $port..."
    local pid=$(netstat -tulpn | grep -w "$port" | awk '{print $7}' | cut -d'/' -f1)
    
    if [ -z "$pid" ]; then
        echo "No process found using port $port"
        return 0
    fi
    
    echo "Found process $pid using port $port"
    echo "Terminating process $pid..."
    kill -9 "$pid" || { echo "Failed to kill process $pid"; return 1; }
    echo "Process $pid terminated successfully"
    
    # Verify port is now free
    sleep 1
    if netstat -tulpn | grep -w "$port" > /dev/null; then
        echo "WARNING: Port $port is still in use after terminating process $pid"
        return 1
    else
        echo "Port $port is now free"
        return 0
    fi
}

free_port() {
    local port=$1
    if netstat -tulpn | grep -w "$port" > /dev/null; then
        echo "Port $port is in use. Attempting to free it..."
        kill_port_process "$port"
    else
        echo "Port $port is already free"
    fi
}

# Main
action=${1:-"check"}
port=${2:-$DEFAULT_PORT}

case "$action" in
    check)
        check_port "$port"
        ;;
    kill)
        kill_port_process "$port"
        ;;
    free)
        free_port "$port"
        ;;
    *)
        echo "Usage: $0 [check|kill|free] [port_number]"
        echo "  check: Check if a port is in use"
        echo "  kill: Kill the process using a port"
        echo "  free: Free a port if it's in use"
        echo "Default port is $DEFAULT_PORT"
        exit 1
        ;;
esac

exit 0 