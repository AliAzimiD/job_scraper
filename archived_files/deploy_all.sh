#!/bin/bash
set -e

# Job Scraper Complete Deployment Wrapper
# This script runs all deployment steps in sequence with secure credential handling

# Print banner
echo "==========================================================="
echo "     Job Scraper Deployment and Configuration Script       "
echo "==========================================================="
echo ""
echo "This script will run all deployment steps in sequence:"
echo "1. Deploy application to VPS"
echo "2. Configure Grafana alerts"
echo "3. Generate monitoring documentation"
echo ""

# Check if files exist
if [[ ! -f "./deploy_to_vps.sh" || ! -f "./setup_grafana_alerts.sh" || ! -f "./document_monitoring.sh" ]]; then
    echo "ERROR: One or more required scripts are missing."
    echo "Make sure all these files exist in the current directory:"
    echo "  - deploy_to_vps.sh"
    echo "  - setup_grafana_alerts.sh"
    echo "  - document_monitoring.sh"
    exit 1
fi

# Make sure scripts are executable
chmod +x deploy_to_vps.sh setup_grafana_alerts.sh document_monitoring.sh

# Prompt for VPS connection details
echo "Enter VPS connection details:"
read -p "VPS IP Address [23.88.125.23]: " VPS_IP
VPS_IP=${VPS_IP:-23.88.125.23}

read -p "VPS Username [root]: " VPS_USER
VPS_USER=${VPS_USER:-root}

echo -n "VPS Password: "
read -s VPS_PASSWORD
echo ""

if [ -z "$VPS_PASSWORD" ]; then
    echo "ERROR: Password cannot be empty"
    exit 1
fi

read -p "Domain Name (leave empty if none): " DOMAIN_NAME

# Export environment variables for the scripts
export VPS_IP
export VPS_USER
export VPS_PASSWORD
export DOMAIN_NAME

# Confirm settings
echo ""
echo "Deployment Settings:"
echo "  - VPS IP: $VPS_IP"
echo "  - VPS User: $VPS_USER"
echo "  - Domain: ${DOMAIN_NAME:-None}"
echo ""

read -p "Do you want to proceed with deployment? (y/n): " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Deployment cancelled."
    exit 0
fi

# Run deployment scripts in sequence
echo ""
echo "==========================================================="
echo "STEP 1: Deploying application to VPS"
echo "==========================================================="
./deploy_to_vps.sh || { echo "ERROR: Application deployment failed."; exit 1; }

echo ""
echo "==========================================================="
echo "STEP 2: Setting up Grafana alerts"
echo "==========================================================="
./setup_grafana_alerts.sh || { echo "WARNING: Grafana alert setup encountered issues."; }

echo ""
echo "==========================================================="
echo "STEP 3: Generating monitoring documentation"
echo "==========================================================="
./document_monitoring.sh || { echo "WARNING: Documentation generation encountered issues."; }

echo ""
echo "==========================================================="
echo "Deployment Complete!"
echo "==========================================================="
echo ""
echo "Your Job Scraper application is now deployed and configured."
echo ""
echo "URLs to access your system:"
if [ -n "$DOMAIN_NAME" ]; then
    echo "  - Application: https://$DOMAIN_NAME"
    echo "  - Grafana: https://$DOMAIN_NAME/grafana (login: admin/admin)"
    echo "  - Prometheus: https://$DOMAIN_NAME/prometheus"
else
    echo "  - Application: http://$VPS_IP:5000"
    echo "  - Grafana: http://$VPS_IP:3000 (login: admin/admin)"
    echo "  - Prometheus: http://$VPS_IP:9090"
fi
echo ""
echo "Documentation generated in: ./monitoring_docs"
echo "==========================================================="

# Clear credential environment variables
unset VPS_PASSWORD

exit 0 