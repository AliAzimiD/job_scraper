#!/bin/bash

# Update Job Scraper with Monitoring Stack
# This script adds Prometheus and Grafana monitoring to an existing job scraper deployment

set -e

echo "====================================================="
echo "Job Scraper Monitoring Integration Setup"
echo "====================================================="
echo "This script will upgrade your existing job scraper deployment"
echo "with Prometheus and Grafana monitoring capabilities."
echo

# Check if running with sudo/root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script with sudo or as root."
  exit 1
fi

# Check for required tools
echo "Checking dependencies..."
for cmd in docker docker-compose curl wget jq grep; do
  if ! command -v $cmd &> /dev/null; then
    echo "Error: $cmd is required but not installed. Please install it first."
    exit 1
  fi
done

echo "✓ All dependencies are installed."
echo

# Check if job scraper is already running
JOB_SCRAPER_RUNNING=$(docker ps --format '{{.Names}}' | grep -c "job-scraper-web" || true)
if [ "$JOB_SCRAPER_RUNNING" -eq 0 ]; then
  echo "Warning: job-scraper-web container is not running."
  echo "Monitoring will be set up, but may not work fully until the job scraper is started."
  echo
fi

# Create necessary directories
echo "Creating configuration directories..."
mkdir -p prometheus grafana/provisioning/datasources grafana/dashboards
echo "✓ Directories created."
echo

# Check if the Docker network exists
NETWORK_EXISTS=$(docker network ls | grep -c "job-scraper-network" || true)
if [ "$NETWORK_EXISTS" -eq 0 ]; then
  echo "Creating Docker network: job-scraper-network"
  docker network create job-scraper-network
  echo "✓ Network created."
else
  echo "✓ Network job-scraper-network already exists."
fi
echo

# Check if monitoring files already exist
if [ -f "docker-compose.monitoring.yml" ] && [ -f "prometheus/prometheus.yml" ]; then
  echo "Monitoring configuration files already exist."
  read -p "Do you want to overwrite them? (y/n): " OVERWRITE
  if [[ ! "$OVERWRITE" =~ ^[Yy]$ ]]; then
    echo "Keeping existing files. Update aborted."
    exit 0
  fi
fi

# Update requirements if needed
echo "Checking requirements.txt..."
if grep -q "prometheus-client" requirements.txt; then
  echo "✓ Prometheus client already in requirements.txt"
else
  echo "Adding prometheus-client to requirements.txt..."
  echo "prometheus-client>=0.17.0" >> requirements.txt
  echo "✓ Updated requirements.txt"
fi
echo

# Update permissions
echo "Setting correct permissions..."
chmod +x start_monitoring.sh
echo "✓ Permissions updated."
echo

# Start monitoring
echo "====================================================="
echo "Setup complete! You can now start the monitoring stack with:"
echo "./start_monitoring.sh"
echo
echo "For more information on using the monitoring features,"
echo "please see the MONITORING.md documentation file."
echo "====================================================="

# Ask to start monitoring now
read -p "Do you want to start the monitoring stack now? (y/n): " START_NOW
if [[ "$START_NOW" =~ ^[Yy]$ ]]; then
  ./start_monitoring.sh
fi 