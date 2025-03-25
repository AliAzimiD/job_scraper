"""
API views blueprint for the Job Scraper application.

This module contains the API routes for the application,
providing JSON responses for programmatic interaction.
"""

import json
import uuid
import os
from datetime import datetime
from typing import Dict, Any, Optional, List

from flask import Blueprint, request, jsonify, current_app, send_from_directory
from marshmallow import Schema, fields, validate, ValidationError

# Create blueprint
api_bp = Blueprint('api', __name__)


# Validation schemas
class ScrapeRequestSchema(Schema):
    """Validation schema for scrape requests."""
    max_pages = fields.Integer(required=True, validate=validate.Range(min=1, max=100))
    keywords = fields.String(required=False)
    location = fields.String(required=False)
    source_website = fields.String(required=False)


class ExportRequestSchema(Schema):
    """Validation schema for export requests."""
    format = fields.String(required=True, validate=validate.OneOf(["json", "csv", "sql"]))
    filters = fields.Dict(required=False)


class ImportRequestSchema(Schema):
    """Validation schema for import requests."""
    file = fields.String(required=True)
    format = fields.String(required=False)
    update_existing = fields.Boolean(required=False, default=True)


# Global state for mock scraper status
_scraper_status = {
    'running': False,
    'status': 'idle',
    'start_time': None,
    'end_time': None,
    'progress': 0,
    'jobs_found': 0,
    'jobs_added': 0,
    'error': None
}


@api_bp.route('/scraper-status')
def get_scraper_status():
    """
    Get the current status of the scraper.
    
    Returns:
        JSON with scraper status
    """
    return jsonify(_scraper_status)


@api_bp.route('/start-scrape', methods=['POST'])
def start_scrape():
    """
    Start a new scraping job.
    
    Returns:
        JSON with operation result
    """
    # Validate input
    schema = ScrapeRequestSchema()
    try:
        data = schema.load(request.json or {})
    except ValidationError as err:
        return jsonify({
            'success': False,
            'message': 'Validation error',
            'errors': err.messages
        }), 400
    
    # Check if scraper is already running
    if _scraper_status['running']:
        return jsonify({
            'success': False,
            'message': 'Scraper is already running',
            'status': _scraper_status
        })
    
    # Start mock scraper for demonstration
    _scraper_status.update({
        'running': True,
        'status': 'running',
        'start_time': datetime.utcnow().isoformat(),
        'end_time': None,
        'progress': 0,
        'jobs_found': 0,
        'jobs_added': 0,
        'error': None
    })
    
    # Normally, you would start the actual scraper here
    # This would be an async task or background thread
    import threading
    import time
    
    def mock_scraper():
        """Simulate scraper progress for demonstration."""
        max_pages = data.get('max_pages', 10)
        
        for i in range(max_pages + 1):
            # Update progress
            _scraper_status['progress'] = (i / max_pages) * 100
            _scraper_status['jobs_found'] = i * 5
            _scraper_status['jobs_added'] = i * 3
            
            # Sleep to simulate work
            time.sleep(2)
            
            # Check if we should stop
            if not _scraper_status['running']:
                _scraper_status['status'] = 'cancelled'
                _scraper_status['end_time'] = datetime.utcnow().isoformat()
                return
        
        # Complete the scraper
        _scraper_status.update({
            'running': False,
            'status': 'completed',
            'end_time': datetime.utcnow().isoformat(),
            'progress': 100
        })
    
    # Start scraper in background thread
    thread = threading.Thread(target=mock_scraper)
    thread.daemon = True
    thread.start()
    
    return jsonify({
        'success': True,
        'message': 'Scraper started successfully',
        'status': _scraper_status
    })


@api_bp.route('/stop-scrape', methods=['POST'])
def stop_scrape():
    """
    Stop a running scraper.
    
    Returns:
        JSON with operation result
    """
    if not _scraper_status['running']:
        return jsonify({
            'success': False,
            'message': 'Scraper is not running',
            'status': _scraper_status
        })
    
    # Stop the scraper
    _scraper_status['running'] = False
    _scraper_status['status'] = 'stopping'
    
    return jsonify({
        'success': True,
        'message': 'Scraper stopped successfully',
        'status': _scraper_status
    })


@api_bp.route('/export-db', methods=['POST'])
def export_db():
    """
    Export database to a file.
    
    Returns:
        JSON with operation result
    """
    # Validate input
    schema = ExportRequestSchema()
    try:
        data = schema.load(request.json or {})
    except ValidationError as err:
        return jsonify({
            'success': False,
            'message': 'Validation error',
            'errors': err.messages
        }), 400
    
    # Get export format
    export_format = data.get('format', 'json')
    
    # Create upload directory if it doesn't exist
    upload_folder = current_app.config.get('UPLOAD_FOLDER', 'uploads')
    os.makedirs(upload_folder, exist_ok=True)
    
    # Generate filename with timestamp
    timestamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    filename = f"job_export_{timestamp}.{export_format}"
    filepath = os.path.join(upload_folder, filename)
    
    # Create dummy export data
    dummy_data = {
        'count': 2,
        'export_date': timestamp,
        'jobs': [
            {
                'id': 1,
                'title': 'Sample Job 1',
                'company': 'Company A'
            },
            {
                'id': 2,
                'title': 'Sample Job 2',
                'company': 'Company B'
            }
        ]
    }
    
    # Write the file based on format
    try:
        if export_format == 'json':
            with open(filepath, 'w') as f:
                json.dump(dummy_data, f, indent=2)
        elif export_format == 'csv':
            import csv
            with open(filepath, 'w', newline='') as f:
                writer = csv.writer(f)
                writer.writerow(['id', 'title', 'company'])
                for job in dummy_data['jobs']:
                    writer.writerow([job['id'], job['title'], job['company']])
        elif export_format == 'sql':
            with open(filepath, 'w') as f:
                f.write("-- SQL export of job data\n")
                f.write(f"-- Generated on {timestamp}\n\n")
                for job in dummy_data['jobs']:
                    f.write(f"INSERT INTO jobs (id, title, company) VALUES ({job['id']}, '{job['title']}', '{job['company']}');\n")
    except Exception as e:
        return jsonify({
            'success': False,
            'message': f'Export failed: {str(e)}'
        }), 500
    
    return jsonify({
        'success': True,
        'message': f'Database exported to {filename}',
        'file': filename
    })


@api_bp.route('/download/<filename>')
def download_file(filename):
    """
    Download an exported file.
    
    Args:
        filename: Name of the file to download
    
    Returns:
        File download response
    """
    upload_folder = current_app.config.get('UPLOAD_FOLDER', 'uploads')
    return send_from_directory(upload_folder, filename, as_attachment=True) 