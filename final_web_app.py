#!/usr/bin/env python3
"""
Web app for job scraper project - simplified version with corrected paths
This version has dependencies modified to work with basic libraries
"""

import os
import sys
import json
import time
import random
import threading
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

# Ensure upload directory exists
uploads_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'uploads')
os.makedirs(uploads_dir, exist_ok=True)

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('web_app')

# Job scraping status to pass to templates
scraping_status = {
    "is_running": False,
    "start_time": None,
    "jobs_found": 0,
    "error": None,
    "last_completed": None
}

# Add a context processor to inject the current year into templates
@app.context_processor
def inject_current_year():
    return {'current_year': datetime.now().year}

# Add a fallback route for the homepage
@app.route('/')
def index():
    """Render the home page or a fallback HTML if template not found"""
    try:
        return render_template('index.html', title="Job Scraper Dashboard", scraping_status=scraping_status)
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
    try:
        return render_template('status.html', title="System Status", scraping_status=scraping_status)
    except Exception as e:
        logger.error(f"Error rendering status template: {str(e)}")
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

@app.route('/import_export')
def import_export():
    """Render the import/export page"""
    logger.info("Rendering import/export page")
    try:
        return render_template('import_export.html', title="Import/Export Data")
    except Exception as e:
        logger.error(f"Error rendering import_export template: {str(e)}")
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <title>Import/Export Data</title>
        </head>
        <body>
            <h1>Import/Export Data</h1>
            <p>This functionality is under maintenance.</p>
            <p><a href="/">Return to Home</a></p>
        </body>
        </html>
        """

@app.route('/api/start-scrape', methods=['POST'])
def start_scrape():
    """
    API endpoint to start the scraper
    """
    global scraping_status
    
    # If scraper is already running, return error
    if scraping_status['is_running']:
        return jsonify({
            'success': False,
            'message': 'Scraper is already running'
        })
    
    try:
        logger.info("Starting scraper process")
        
        # Update status to indicate scraper is running
        scraping_status['is_running'] = True
        scraping_status['start_time'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        scraping_status['error'] = None
        
        # For demo purposes, we'll simulate a scraper process
        def run_mock_scraper():
            global scraping_status
            
            def scraper_thread():
                # Simulate scraping delay
                time.sleep(5)
                
                # Simulate success or failure
                success = random.random() > 0.2  # 80% chance of success
                
                if success:
                    # Simulate finding a random number of jobs
                    jobs_found = random.randint(50, 200)
                    scraping_status['jobs_found'] = jobs_found
                    scraping_status['error'] = None
                else:
                    # Simulate an error
                    errors = [
                        "Network connection error",
                        "API rate limit exceeded",
                        "Source website structure changed"
                    ]
                    scraping_status['error'] = random.choice(errors)
                
                # Mark scraping as complete
                scraping_status['is_running'] = False
                scraping_status['last_completed'] = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
            
            thread = threading.Thread(target=scraper_thread)
            thread.daemon = True
            thread.start()
        
        # Start the mock scraper
        run_mock_scraper()
        
        return jsonify({
            'success': True,
            'message': 'Scraper process started'
        })
        
    except Exception as e:
        logger.error(f"Error starting scraper: {str(e)}")
        
        # Update status to indicate error
        scraping_status['is_running'] = False
        scraping_status['error'] = str(e)
        
        return jsonify({
            'success': False,
            'message': f"Error: {str(e)}"
        })

@app.route('/api/scraper-status')
def get_scraper_status():
    """
    API endpoint to get the current scraper status
    """
    global scraping_status
    return jsonify(scraping_status)

@app.route('/api/export-db', methods=['POST'])
def export_db():
    """
    Export the database in the specified format
    """
    export_format = request.form.get('format', 'json')
    include_raw_data = request.form.get('include_raw_data') == 'on'
    
    try:
        logger.info(f"Exporting database in {export_format} format")
        
        # Generate a unique filename
        timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
        filename = f"job_data_export_{timestamp}.{export_format}"
        filepath = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        
        # In a real implementation, we would query the database and create the export file
        # For demonstration, we'll create a sample export file
        if export_format == 'json':
            sample_data = [
                {"id": 1, "title": "Software Engineer", "company": "Tech Corp", "location": "New York", "salary": "$120,000", "date_posted": "2023-01-15"},
                {"id": 2, "title": "Data Scientist", "company": "Data Inc", "location": "San Francisco", "salary": "$140,000", "date_posted": "2023-01-16"},
                {"id": 3, "title": "Product Manager", "company": "Product Co", "location": "Austin", "salary": "$110,000", "date_posted": "2023-01-17"}
            ]
            
            # Add raw data if requested
            if include_raw_data:
                for job in sample_data:
                    job['raw_data'] = {
                        "html": "<div class='job-listing'>...(long HTML content)...</div>",
                        "metadata": {"source": "example.com", "scrape_date": "2023-01-20"}
                    }
                    
            with open(filepath, 'w') as f:
                json.dump(sample_data, f, indent=2)
                
        elif export_format == 'csv':
            csv_content = "id,title,company,location,salary,date_posted\n"
            csv_content += "1,Software Engineer,Tech Corp,New York,$120000,2023-01-15\n"
            csv_content += "2,Data Scientist,Data Inc,San Francisco,$140000,2023-01-16\n"
            csv_content += "3,Product Manager,Product Co,Austin,$110000,2023-01-17\n"
            
            with open(filepath, 'w') as f:
                f.write(csv_content)
                
        elif export_format == 'sql':
            sql_content = "INSERT INTO jobs (id, title, company, location, salary, date_posted) VALUES\n"
            sql_content += "(1, 'Software Engineer', 'Tech Corp', 'New York', '$120,000', '2023-01-15'),\n"
            sql_content += "(2, 'Data Scientist', 'Data Inc', 'San Francisco', '$140,000', '2023-01-16'),\n"
            sql_content += "(3, 'Product Manager', 'Product Co', 'Austin', '$110,000', '2023-01-17');\n"
            
            with open(filepath, 'w') as f:
                f.write(sql_content)
        
        # Send the file as a download attachment
        return send_file(filepath, as_attachment=True, download_name=filename)
        
    except Exception as e:
        logger.error(f"Error exporting database: {str(e)}")
        return jsonify({
            'success': False,
            'message': f"Error: {str(e)}"
        })

@app.route('/api/import-db', methods=['POST'])
def import_db():
    """
    Import data into the database from an uploaded file
    """
    if 'file' not in request.files:
        return jsonify({
            'success': False,
            'message': 'No file part in the request'
        })
        
    file = request.files['file']
    
    if file.filename == '':
        return jsonify({
            'success': False,
            'message': 'No file selected'
        })
        
    try:
        # Save the uploaded file
        filename = secure_filename(file.filename)
        file_path = os.path.join(app.config['UPLOAD_FOLDER'], filename)
        file.save(file_path)
        
        logger.info(f"File uploaded: {filename}")
        
        # Process the file based on its extension
        records_imported = 0
        file_ext = filename.rsplit('.', 1)[1].lower() if '.' in filename else ''
        
        if file_ext == 'json':
            # Process JSON file
            with open(file_path, 'r') as f:
                data = json.load(f)
                records_imported = len(data)
                # In a real implementation, we would insert this data into the database
                
        elif file_ext == 'csv':
            # Process CSV file
            with open(file_path, 'r') as f:
                # Skip header row
                next(f)
                records_imported = sum(1 for _ in f)
                # In a real implementation, we would parse and insert this data
                
        elif file_ext == 'sql':
            # Process SQL file
            # In a real implementation, we would execute these SQL statements
            # For demo, estimate based on INSERT statements
            with open(file_path, 'r') as f:
                content = f.read()
                records_imported = content.count('INSERT INTO')
                
        else:
            return jsonify({
                'success': False,
                'message': f'Unsupported file format: {file_ext}'
            })
            
        logger.info(f"Imported {records_imported} records")
        
        return jsonify({
            'success': True,
            'message': 'Import completed successfully',
            'records_imported': records_imported
        })
        
    except Exception as e:
        logger.error(f"Error importing data: {str(e)}")
        return jsonify({
            'success': False,
            'message': f"Error: {str(e)}"
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