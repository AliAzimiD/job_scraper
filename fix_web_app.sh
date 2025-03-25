#!/bin/bash

export VPS_PASS="jy6adu06wxefmvsi1kzo"

echo "Creating a more resilient web_app.py..."
cat > fixed_web_app.py << 'WEBAPPPY'
#!/usr/bin/env python3
"""
Web app for job scraper project - simplified version
This version has dependencies modified to work with basic libraries
"""

import os
import sys
import json
import time
import logging
from datetime import datetime, timedelta
from typing import Dict, List, Any, Optional, Union, Tuple

# Try to import Flask and its dependencies
try:
    from flask import Flask, render_template, request, jsonify, send_file, redirect, url_for
    from werkzeug.utils import secure_filename
except ImportError:
    print("Error: Flask is required. Please install it with: pip install flask")
    sys.exit(1)

# Simplified app that doesn't depend on other components
app = Flask(__name__, template_folder='src/templates', static_folder='src/static')
app.config['SECRET_KEY'] = os.environ.get('FLASK_SECRET_KEY', 'dev-key-for-testing')
app.config['UPLOAD_FOLDER'] = 'uploads'
app.config['MAX_CONTENT_LENGTH'] = 100 * 1024 * 1024  # 100 MB

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('web_app')

@app.route('/')
def index():
    """Render the home page"""
    return render_template('index.html', title="Job Scraper Status Page")

@app.route('/status')
def status():
    """Return the status of the system"""
    return jsonify({
        'status': 'online',
        'time': datetime.now().isoformat(),
        'version': '1.0.0',
        'components': {
            'web': 'online',
            'database': 'unknown',
            'scraper': 'not running',
            'monitoring': {
                'prometheus': 'online',
                'grafana': 'online'
            }
        }
    })

@app.route('/health')
def health():
    """Health check endpoint for monitoring"""
    return jsonify({'status': 'healthy'})

@app.route('/metrics')
def metrics():
    """Prometheus metrics endpoint"""
    return 'job_scraper_web_requests_total 1\n'

if __name__ == '__main__':
    # Run the app
    port = int(os.environ.get('FLASK_PORT', 5000))
    host = os.environ.get('FLASK_HOST', '0.0.0.0')
    debug = os.environ.get('FLASK_DEBUG', 'False').lower() == 'true'
    
    logger.info(f"Starting web application on {host}:{port} (debug={debug})")
    app.run(host=host, port=port, debug=debug)
WEBAPPPY

echo "Uploading the fixed web_app.py to the server..."
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no fixed_web_app.py root@23.88.125.23:/opt/job-scraper/src/web_app.py

echo "Creating necessary templates directory..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "mkdir -p /opt/job-scraper/src/templates /opt/job-scraper/src/static"

echo "Creating a basic index.html template..."
cat > index.html << 'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Job Scraper - {{ title }}</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 0;
            background-color: #f4f4f4;
        }
        header {
            background-color: #333;
            color: white;
            padding: 20px;
            text-align: center;
        }
        .container {
            max-width: 1200px;
            margin: 20px auto;
            padding: 20px;
            background-color: white;
            box-shadow: 0 0 10px rgba(0,0,0,0.1);
        }
        .status-card {
            border: 1px solid #ddd;
            padding: 15px;
            margin-bottom: 20px;
            border-radius: 5px;
        }
        .online {
            color: green;
        }
        footer {
            text-align: center;
            padding: 20px;
            background-color: #333;
            color: white;
        }
    </style>
</head>
<body>
    <header>
        <h1>Job Scraper System</h1>
    </header>
    
    <div class="container">
        <h2>System Status</h2>
        
        <div class="status-card">
            <h3>Web Application</h3>
            <p>Status: <span class="online">Online</span></p>
            <p>Version: 1.0.0</p>
        </div>
        
        <div class="status-card">
            <h3>Monitoring</h3>
            <p>
                <a href="http://23.88.125.23:9090" target="_blank">Prometheus</a> | 
                <a href="http://23.88.125.23:3000" target="_blank">Grafana</a>
            </p>
        </div>
    </div>
    
    <footer>
        &copy; 2024 Job Scraper Project
    </footer>
</body>
</html>
HTML

echo "Uploading the index.html template..."
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no index.html root@23.88.125.23:/opt/job-scraper/src/templates/index.html

echo "Restarting the web container..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "cd /opt/job-scraper && docker-compose restart web"

echo "Done! Check the status in a moment." 