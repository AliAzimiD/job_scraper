#!/usr/bin/env python3
"""
Web routes for the Job Scraper application.
Defines all the routes and API endpoints for the web interface.
"""

import os
import json
import time
import threading
import logging
from datetime import datetime
from typing import Dict, Any

from flask import render_template, request, jsonify, current_app, Blueprint
from werkzeug.utils import secure_filename

# Configure logging
logger = logging.getLogger(__name__)

# Global status dictionary to track scraper status
scraping_status = {
    "running": False,
    "start_time": None,
    "end_time": None,
    "jobs_found": 0,
    "jobs_added": 0,
    "status": "idle",
    "progress": 0,
    "error": None
}

def configure_routes(app):
    """Configure routes for the Flask application
    
    Args:
        app: Flask application instance
    """
    # Ensure upload directory exists
    uploads_dir = os.path.join(app.root_path, app.config.get('UPLOAD_FOLDER', 'uploads'))
    os.makedirs(uploads_dir, exist_ok=True)
    
    # Context processors
    @app.context_processor
    def inject_current_year():
        """Inject current year into templates."""
        return {"current_year": datetime.now().year}
    
    # Routes
    @app.route('/')
    def index():
        """Render the main dashboard page."""
        try:
            return render_template('dashboard.html')
        except Exception as e:
            logger.error(f"Error rendering dashboard: {str(e)}")
            # Fallback to simple HTML if template is not found
            return f"""
            <html>
                <head><title>Job Scraper</title></head>
                <body>
                    <h1>Job Scraper Dashboard</h1>
                    <p>Application is running but the dashboard template could not be loaded.</p>
                    <p>Error: {str(e)}</p>
                </body>
            </html>
            """
    
    @app.route('/status')
    def status():
        """Render the status page showing scraper status."""
        return render_template('status.html', status=scraping_status)
    
    @app.route('/import_export')
    def import_export():
        """Render the import/export page."""
        return render_template('import_export.html')
    
    # API endpoints
    @app.route('/api/start-scrape', methods=['POST'])
    def start_scrape():
        """Start the job scraper."""
        if scraping_status["running"]:
            return jsonify({
                "success": False,
                "message": "Scraper is already running",
                "status": scraping_status
            }), 409
        
        try:
            # Get parameters from request
            data = request.get_json() or {}
            max_pages = data.get('max_pages', None)
            keywords = data.get('keywords', None)
            locations = data.get('locations', None)
            
            # Update status
            scraping_status.update({
                "running": True,
                "start_time": datetime.now().isoformat(),
                "end_time": None,
                "jobs_found": 0,
                "jobs_added": 0,
                "status": "starting",
                "progress": 0,
                "error": None
            })
            
            # Mock scraper function - in production, this would call the actual scraper
            def run_mock_scraper():
                # Simulate scraping delay
                def scraper_thread():
                    try:
                        # Update status to running
                        scraping_status["status"] = "running"
                        
                        # Simulate progress
                        total_steps = 10
                        for i in range(total_steps + 1):
                            if not scraping_status["running"]:
                                # Scraper was stopped
                                return
                            
                            # Update progress
                            scraping_status["progress"] = i * 10
                            scraping_status["jobs_found"] = i * 5  # Mock job count
                            scraping_status["jobs_added"] = i * 3  # Mock added count
                            
                            # Sleep to simulate work
                            time.sleep(2)
                        
                        # Complete the scraping
                        scraping_status.update({
                            "running": False,
                            "end_time": datetime.now().isoformat(),
                            "status": "completed",
                            "progress": 100
                        })
                        
                    except Exception as e:
                        # Handle any errors
                        scraping_status.update({
                            "running": False,
                            "end_time": datetime.now().isoformat(),
                            "status": "error",
                            "error": str(e)
                        })
                        logger.error(f"Error in scraper thread: {str(e)}")
                
                # Start the scraper in a separate thread
                thread = threading.Thread(target=scraper_thread)
                thread.daemon = True
                thread.start()
            
            # Start the scraper
            run_mock_scraper()
            
            return jsonify({
                "success": True,
                "message": "Scraper started successfully",
                "status": scraping_status
            })
            
        except Exception as e:
            logger.error(f"Error starting scraper: {str(e)}")
            scraping_status.update({
                "running": False,
                "status": "error",
                "error": str(e)
            })
            return jsonify({
                "success": False,
                "message": f"Error starting scraper: {str(e)}",
                "status": scraping_status
            }), 500
    
    @app.route('/api/stop-scrape', methods=['POST'])
    def stop_scrape():
        """Stop the running scraper."""
        if not scraping_status["running"]:
            return jsonify({
                "success": False,
                "message": "Scraper is not running",
                "status": scraping_status
            }), 409
        
        try:
            # Update status
            scraping_status.update({
                "running": False,
                "end_time": datetime.now().isoformat(),
                "status": "stopped",
            })
            
            return jsonify({
                "success": True,
                "message": "Scraper stopped successfully",
                "status": scraping_status
            })
            
        except Exception as e:
            logger.error(f"Error stopping scraper: {str(e)}")
            return jsonify({
                "success": False,
                "message": f"Error stopping scraper: {str(e)}",
                "status": scraping_status
            }), 500
    
    @app.route('/api/scraper-status')
    def get_scraper_status():
        """Get the current status of the scraper."""
        return jsonify(scraping_status)
    
    @app.route('/api/export-db', methods=['POST'])
    def export_db():
        """Export the database to a file."""
        try:
            data = request.get_json() or {}
            format_type = data.get('format', 'json')
            
            if format_type not in ['json', 'csv', 'sql']:
                return jsonify({
                    "success": False,
                    "message": f"Unsupported format: {format_type}"
                }), 400
            
            # Mock export function
            # In production, this would call the actual export function from DataManager
            
            # Create a temporary file
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            filename = f"job_export_{timestamp}.{format_type}"
            file_path = os.path.join(current_app.config.get('UPLOAD_FOLDER', 'uploads'), filename)
            
            # Ensure the upload directory exists
            os.makedirs(os.path.dirname(file_path), exist_ok=True)
            
            # Create a sample export file
            if format_type == 'json':
                with open(file_path, 'w') as f:
                    json.dump({
                        "jobs": [
                            {"id": 1, "title": "Sample Job 1", "company": "Company A"},
                            {"id": 2, "title": "Sample Job 2", "company": "Company B"}
                        ],
                        "export_date": timestamp,
                        "count": 2
                    }, f, indent=2)
            elif format_type == 'csv':
                with open(file_path, 'w') as f:
                    f.write("id,title,company\n")
                    f.write("1,Sample Job 1,Company A\n")
                    f.write("2,Sample Job 2,Company B\n")
            else:  # SQL
                with open(file_path, 'w') as f:
                    f.write("-- SQL Export of jobs\n")
                    f.write("INSERT INTO jobs (id, title, company) VALUES (1, 'Sample Job 1', 'Company A');\n")
                    f.write("INSERT INTO jobs (id, title, company) VALUES (2, 'Sample Job 2', 'Company B');\n")
            
            return jsonify({
                "success": True,
                "message": f"Database exported to {filename}",
                "file": filename
            })
            
        except Exception as e:
            logger.error(f"Error exporting database: {str(e)}")
            return jsonify({
                "success": False,
                "message": f"Error exporting database: {str(e)}"
            }), 500
    
    @app.route('/api/import-db', methods=['POST'])
    def import_db():
        """Import data from a file."""
        if 'file' not in request.files:
            return jsonify({
                "success": False,
                "message": "No file provided"
            }), 400
        
        file = request.files['file']
        
        if file.filename == '':
            return jsonify({
                "success": False,
                "message": "No file selected"
            }), 400
        
        try:
            # Get parameters
            update_existing = request.form.get('update_existing', 'true').lower() == 'true'
            
            # Determine file type from extension
            filename = file.filename
            format_type = None
            
            if filename.endswith('.json'):
                format_type = 'json'
            elif filename.endswith('.csv'):
                format_type = 'csv'
            elif filename.endswith('.sql'):
                format_type = 'sql'
            else:
                return jsonify({
                    "success": False,
                    "message": f"Unsupported file format: {filename}"
                }), 400
            
            # Save the file
            upload_folder = current_app.config.get('UPLOAD_FOLDER', 'uploads')
            os.makedirs(upload_folder, exist_ok=True)
            file_path = os.path.join(upload_folder, secure_filename(file.filename))
            file.save(file_path)
            
            # Mock import process
            # In production, this would call the actual import function from DataManager
            time.sleep(2)  # Simulate processing time
            
            # Return success response
            return jsonify({
                "success": True,
                "message": f"File {filename} imported successfully",
                "stats": {
                    "records_read": 2,
                    "records_imported": 2,
                    "errors": 0
                }
            })
            
        except Exception as e:
            logger.error(f"Error importing file: {str(e)}")
            return jsonify({
                "success": False,
                "message": f"Error importing file: {str(e)}"
            }), 500
    
    # Health and metrics endpoints
    @app.route('/health')
    def health():
        """Health check endpoint."""
        return jsonify({"status": "ok", "timestamp": datetime.now().isoformat()})
    
    @app.route('/metrics')
    def metrics():
        """Metrics endpoint (provided by Prometheus metrics)."""
        # This endpoint is typically handled by the Prometheus client library
        # or a dedicated metrics blueprint
        return "Metrics endpoint (to be implemented by Prometheus client)"
    
    # Error handlers
    @app.errorhandler(404)
    def page_not_found(e):
        """Handle 404 errors."""
        logger.warning(f"404 error: {request.path}")
        return render_template('errors/404.html'), 404
    
    @app.errorhandler(500)
    def server_error(e):
        """Handle 500 errors."""
        logger.error(f"500 error: {str(e)}")
        return render_template('errors/500.html', error=str(e)), 500
    
    return app 