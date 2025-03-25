#!/bin/bash

export VPS_PASS="jy6adu06wxefmvsi1kzo"

echo "Setting up custom web app on port 5001..."

# Kill any existing process on port 5001
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "lsof -ti:5001 | xargs kill -9 2>/dev/null || true"

# Create run script
cat > run_on_port_5001.py << 'EOF'
#!/usr/bin/env python3
"""
Simple wrapper to run the web app on port 5001
"""
import os
from src.simple_web_app import app

if __name__ == '__main__':
    port = 5001
    host = '0.0.0.0'
    print(f"Starting web application on {host}:{port}")
    app.run(host=host, port=port)
EOF

# Upload the script
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no run_on_port_5001.py root@23.88.125.23:/opt/job-scraper/

# Make it executable
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "chmod +x /opt/job-scraper/run_on_port_5001.py"

# Run it in the background
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "cd /opt/job-scraper && nohup python3 run_on_port_5001.py > custom_web_app.log 2>&1 &"

# Wait a moment for the app to start
echo "Waiting for app to start..."
sleep 3

# Test if the app is running
echo "Testing if the app is running..."
HEALTH_STATUS=$(sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "curl -s -o /dev/null -w '%{http_code}' http://localhost:5001/health || echo 'Failed'")

if [ "$HEALTH_STATUS" == "200" ]; then
  echo "Custom web app is running on http://23.88.125.23:5001"
else
  echo "Failed to start custom web app. Status: $HEALTH_STATUS"
  echo "Check logs on the server with: cat /opt/job-scraper/custom_web_app.log"
fi 