#!/bin/bash

# Start Monitoring Stack for Job Scraper
# This script sets up and starts the Prometheus and Grafana monitoring stack

set -e

echo "Starting Job Scraper Monitoring Stack..."

# Create necessary directories if they don't exist
mkdir -p prometheus grafana/provisioning/datasources grafana/dashboards

# Check if docker is running
if ! docker info > /dev/null 2>&1; then
    echo "Error: Docker does not seem to be running. Please start Docker first."
    exit 1
fi

# Check if the job-scraper network exists
if ! docker network inspect job-scraper-network > /dev/null 2>&1; then
    echo "Creating job-scraper-network..."
    docker network create job-scraper-network
fi

# Check if the monitoring services are already running
if docker ps --format '{{.Names}}' | grep -q "job-scraper-prometheus\|job-scraper-grafana"; then
    echo "Monitoring services are already running. Do you want to restart them? (y/n)"
    read -r restart
    if [[ "$restart" =~ ^[Yy]$ ]]; then
        echo "Stopping existing monitoring services..."
        docker-compose -f docker-compose.monitoring.yml down
    else
        echo "Exiting without restarting services."
        exit 0
    fi
fi

# Start the monitoring stack
echo "Starting monitoring services..."
docker-compose -f docker-compose.monitoring.yml up -d

# Check if services started successfully
if docker ps --format '{{.Names}}' | grep -q "job-scraper-prometheus" && \
   docker ps --format '{{.Names}}' | grep -q "job-scraper-grafana"; then
    echo "Monitoring services started successfully!"
    echo "Access Prometheus at: http://localhost:9090"
    echo "Access Grafana at: http://localhost:3000 (default credentials: admin/admin)"
else
    echo "Error: Some services failed to start. Check the logs with: docker-compose -f docker-compose.monitoring.yml logs"
    exit 1
fi

# Verify Prometheus targets
echo "Checking Prometheus targets (this may take a few seconds)..."
sleep 10  # Give Prometheus time to start up and scrape targets

# Use curl to check Prometheus targets
target_status=$(curl -s http://localhost:9090/api/v1/targets | grep -o '"health":"up"' | wc -l)
total_targets=$(curl -s http://localhost:9090/api/v1/targets | grep -o '"health"' | wc -l)

echo "Targets up: $target_status / $total_targets"

if [ "$target_status" -eq 0 ]; then
    echo "Warning: No targets are up. Check your configuration and that all services are running."
    echo "Detailed target status can be viewed at: http://localhost:9090/targets"
elif [ "$target_status" -lt "$total_targets" ]; then
    echo "Warning: Some targets are down. Check Prometheus at http://localhost:9090/targets"
else
    echo "All Prometheus targets are up!"
fi

echo "Monitoring stack setup complete!"
echo "You can view the Job Scraper dashboard in Grafana at: http://localhost:3000/d/job-scraper-dashboard" 