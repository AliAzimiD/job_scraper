#!/bin/bash

export VPS_PASS="jy6adu06wxefmvsi1kzo"

echo "Uploading templates, static files, and simplified web app to VPS..."

# Create required directories on VPS
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "mkdir -p /opt/job-scraper/src/templates /opt/job-scraper/src/static/css /opt/job-scraper/src/static/js"

# Upload template files
echo "Uploading template files..."
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no src/templates/base.html root@23.88.125.23:/opt/job-scraper/src/templates/
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no src/templates/index.html root@23.88.125.23:/opt/job-scraper/src/templates/
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no src/templates/status.html root@23.88.125.23:/opt/job-scraper/src/templates/

# Upload static files
echo "Uploading CSS and JavaScript files..."
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no src/static/css/style.css root@23.88.125.23:/opt/job-scraper/src/static/css/
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no src/static/js/script.js root@23.88.125.23:/opt/job-scraper/src/static/js/

# Upload simplified web app
echo "Uploading simplified web app..."
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no src/simple_web_app.py root@23.88.125.23:/opt/job-scraper/src/

# Make the web app executable on the VPS
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "chmod +x /opt/job-scraper/src/simple_web_app.py"

# Run the simple web app in the background
echo "Starting the simplified web app on the VPS..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "cd /opt/job-scraper && python3 -m src.simple_web_app > /opt/job-scraper/simple_web_app.log 2>&1 &"

echo "Upload completed. Simple web app started on the VPS."
echo "Web app URL: http://23.88.125.23:5000" 