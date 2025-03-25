#!/usr/bin/env python3
"""
Web app for job scraper project - simplified version with corrected paths
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

# Change template folder path to the absolute path
template_dir = os.path.abspath('/app/src/templates')
static_dir = os.path.abspath('/app/src/static')

# Simplified app with absolute paths
app = Flask(__name__, template_folder=template_dir, static_folder=static_dir)
app.config['SECRET_KEY'] = os.environ.get('FLASK_SECRET_KEY', 'dev-key-for-testing')
app.config['UPLOAD_FOLDER'] = 'uploads'
app.config['MAX_CONTENT_LENGTH'] = 100 * 1024 * 1024  # 100 MB

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('web_app')

# Add a fallback route for the homepage
@app.route('/')
def index():
    """Render the home page or a fallback HTML if template not found"""
    try:
        return render_template('index.html', title="Job Scraper Status Page")
    except Exception as e:
        logger.error(f"Error rendering template: {str(e)}")
        # Return a simple HTML page if template is not found
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Job Scraper Status</title>
        </head>
        <body>
            <h1>Job Scraper System</h1>
            <p>Status: Online</p>
            <p>Monitoring:</p>
            <ul>
                <li><a href="http://23.88.125.23:9090">Prometheus</a></li>
                <li><a href="http://23.88.125.23:3000">Grafana</a></li>
            </ul>
        </body>
        </html>
        """

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
    logger.info(f"Template directory: {template_dir}")
    app.run(host=host, port=port, debug=debug) 