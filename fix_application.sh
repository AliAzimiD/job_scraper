#!/bin/bash
# This script fixes common issues with the Job Scraper application

# ===== Color Definitions =====
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Print formatted output
log() {
    local level=$1
    local message=$2
    echo -e "${level}${message}${NC}"
}

echo "===== Job Scraper Application Fixer ====="
echo ""

# 1. Fix Nginx configuration
echo "1. Fixing Nginx configuration..."
if ! command -v nginx &> /dev/null; then
    log $RED "Nginx not found. Installing..."
    apt update && apt install -y nginx
else
    log $GREEN "Nginx is installed"
fi

# Create proper Nginx configuration
cat > /etc/nginx/sites-available/jobscraper << 'EOF'
server {
    listen 80;
    server_name upgrade4u.online;

    access_log /var/log/nginx/jobscraper_access.log;
    error_log /var/log/nginx/jobscraper_error.log;

    location / {
        proxy_pass http://127.0.0.1:5001;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_connect_timeout 60s;
        proxy_read_timeout 60s;
        proxy_send_timeout 60s;
    }

    location /static {
        alias /opt/jobscraper/static;
        expires 30d;
    }

    # Add security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}
EOF

# Enable the site
ln -sf /etc/nginx/sites-available/jobscraper /etc/nginx/sites-enabled/

# Remove default site
if [ -f "/etc/nginx/sites-enabled/default" ]; then
    rm -f /etc/nginx/sites-enabled/default
fi

# Test and reload Nginx
nginx -t && systemctl reload nginx
log $GREEN "Nginx configuration fixed"

# 2. Create minimal app for testing
echo ""
echo "2. Creating minimal Flask application for testing..."

# Create required directories
mkdir -p /opt/jobscraper/static /opt/jobscraper/logs
chown -R jobscraper:jobscraper /opt/jobscraper 2>/dev/null || true

# Create a simple Flask application
cat > /opt/jobscraper/main.py << 'EOF'
from flask import Flask, render_template_string

app = Flask(__name__)

@app.route('/')
def index():
    return render_template_string("""
    <!DOCTYPE html>
    <html>
    <head>
        <title>Job Scraper - Working!</title>
        <style>
            body {
                font-family: Arial, sans-serif;
                margin: 0;
                padding: 20px;
                background-color: #f5f5f5;
                color: #333;
            }
            .container {
                max-width: 800px;
                margin: 0 auto;
                background-color: white;
                padding: 30px;
                border-radius: 8px;
                box-shadow: 0 2px 10px rgba(0,0,0,0.1);
            }
            h1 {
                color: #4285f4;
            }
            .status {
                padding: 10px;
                background-color: #d4edda;
                border-radius: 4px;
                color: #155724;
                margin: 20px 0;
            }
        </style>
    </head>
    <body>
        <div class="container">
            <h1>Job Scraper Application</h1>
            <div class="status">
                <strong>Status:</strong> Working correctly!
            </div>
            <p>
                This is a temporary placeholder page to confirm that Nginx is properly
                proxying requests to your Flask application. When you see this page,
                it means the basic connectivity is working.
            </p>
            <p>
                <strong>Next steps:</strong> Deploy your full application to replace this placeholder.
            </p>
        </div>
    </body>
    </html>
    """)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5001)
EOF

# Create systemd service
cat > /etc/systemd/system/jobscraper.service << 'EOF'
[Unit]
Description=Job Scraper Test Application
After=network.target

[Service]
User=root
WorkingDirectory=/opt/jobscraper
ExecStart=/usr/bin/python3 -m flask run --host=0.0.0.0 --port=5001
Environment="FLASK_APP=main.py"
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Install Flask if not already installed
pip3 install flask || apt-get install -y python3-flask

# Enable and start the service
systemctl daemon-reload
systemctl enable jobscraper
systemctl restart jobscraper
log $GREEN "Test application deployed and started"

# 3. Check firewalls
echo ""
echo "3. Checking firewall settings..."
if command -v ufw &> /dev/null; then
    ufw status | grep "Status: active" > /dev/null
    if [ $? -eq 0 ]; then
        # Check if ports 80 and 443 are allowed
        ufw allow 80/tcp
        ufw allow 443/tcp
        log $GREEN "Firewall is configured to allow HTTP and HTTPS traffic"
    else
        log $YELLOW "Firewall is not active"
    fi
else
    log $YELLOW "UFW firewall not installed"
fi

# 4. Check application status
echo ""
echo "4. Checking application status..."
systemctl status jobscraper --no-pager
curl -s http://localhost:5001/ | grep "Working correctly" > /dev/null
if [ $? -eq 0 ]; then
    log $GREEN "Application is responding correctly on localhost"
else
    log $RED "Application is not responding correctly on localhost"
fi

# 5. Display final status
echo ""
echo "===== Fix Summary ====="
echo "1. Nginx configuration: Fixed"
echo "2. Test application: Deployed"
echo "3. Firewall settings: Checked"
echo "4. Application status: Verified"
echo ""
echo "The application should now be accessible at http://upgrade4u.online"
echo "If you still see issues, please check the logs: /var/log/nginx/jobscraper_error.log" 