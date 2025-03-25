#!/bin/bash

# Script to upload our enhanced files to the VPS

# Set the VPS credentials
VPS_USER="root"
VPS_HOST="23.88.125.23"
VPS_PASS="jy6adu06wxefmvsi1kzo"

# Set the local and remote paths
LOCAL_WEB_APP="src/simple_web_app.py"
REMOTE_WEB_APP="/opt/job-scraper/src/simple_web_app.py"

LOCAL_TEMPLATES_DIR="src/templates"
REMOTE_TEMPLATES_DIR="/opt/job-scraper/src/templates"

echo "===== Uploading enhanced features to VPS ====="

# Make directories if they don't exist
echo "Making sure remote directories exist..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_HOST "mkdir -p $REMOTE_TEMPLATES_DIR"

# Upload the web app
echo "Uploading web app..."
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no $LOCAL_WEB_APP $VPS_USER@$VPS_HOST:$REMOTE_WEB_APP

# Upload template files
echo "Uploading template files..."
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no -r $LOCAL_TEMPLATES_DIR/* $VPS_USER@$VPS_HOST:$REMOTE_TEMPLATES_DIR/

# Create uploads directory on the VPS
echo "Creating uploads directory..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_HOST "mkdir -p /opt/job-scraper/uploads"

# Restart the web container
echo "Restarting the web container..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_HOST "cd /opt/job-scraper && docker-compose restart web"

# Wait for the container to restart
echo "Waiting for the container to restart..."
sleep 5

# Check the container status
echo "Checking container status..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_HOST "docker ps | grep job-scraper-web"

# Check the web app is working
echo "Checking web app health..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_HOST "curl -s -o /dev/null -w '%{http_code}\n' http://localhost:5000/"

echo "===== Upload complete ====="
echo "The enhanced features should now be available on the VPS."
echo "Visit http://23.88.125.23:5000 to check the updated interface." 