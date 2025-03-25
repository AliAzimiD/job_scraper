"""
Import/Export views blueprint for the Job Scraper application.

This module contains the routes for importing and exporting data,
including JSON, CSV, and SQL formats.
"""

import os
from flask import Blueprint, render_template, request, redirect, url_for, flash, current_app, jsonify
from werkzeug.utils import secure_filename

# Create blueprint
import_export_bp = Blueprint('import_export', __name__)


@import_export_bp.route('/')
def index():
    """
    Render the import/export page.
    
    Returns:
        Rendered import/export template
    """
    return render_template('import_export.html')


@import_export_bp.route('/exports')
def list_exports():
    """
    List all exported files.
    
    Returns:
        Rendered exports template with file list
    """
    upload_folder = current_app.config.get('UPLOAD_FOLDER', 'uploads')
    
    # Get all files in the upload folder
    if not os.path.exists(upload_folder):
        os.makedirs(upload_folder, exist_ok=True)
    
    files = []
    for filename in os.listdir(upload_folder):
        filepath = os.path.join(upload_folder, filename)
        if os.path.isfile(filepath):
            # Get file stats
            stats = os.stat(filepath)
            files.append({
                'name': filename,
                'size': stats.st_size,
                'created': stats.st_ctime,
                'format': filename.split('.')[-1]
            })
    
    # Sort files by creation time, newest first
    files.sort(key=lambda x: x['created'], reverse=True)
    
    return render_template('import_export/exports.html', files=files)


@import_export_bp.route('/upload', methods=['POST'])
def upload_file():
    """
    Handle file upload for importing.
    
    Returns:
        Redirect to import/export page with status message
    """
    if 'file' not in request.files:
        flash('No file part', 'error')
        return redirect(url_for('import_export.index'))
    
    file = request.files['file']
    if file.filename == '':
        flash('No selected file', 'error')
        return redirect(url_for('import_export.index'))
    
    if file:
        filename = secure_filename(file.filename)
        upload_folder = current_app.config.get('UPLOAD_FOLDER', 'uploads')
        
        # Create upload folder if it doesn't exist
        os.makedirs(upload_folder, exist_ok=True)
        
        filepath = os.path.join(upload_folder, filename)
        file.save(filepath)
        
        flash(f'File {filename} uploaded successfully', 'success')
        return redirect(url_for('import_export.index'))
    
    flash('Unknown error during file upload', 'error')
    return redirect(url_for('import_export.index')) 