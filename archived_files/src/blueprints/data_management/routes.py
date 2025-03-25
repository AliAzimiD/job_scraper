import os
import json
import zipfile
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, List, Optional

from flask import Blueprint, render_template, current_app, request, jsonify, flash, redirect
from flask import url_for, send_file, Response
from werkzeug.utils import secure_filename
import pandas as pd

from ...log_setup import get_logger

# Get logger
logger = get_logger("data_management")

# Create blueprint
data_bp = Blueprint(
    'data',
    __name__,
    template_folder='templates',
    static_folder='static'
)

# Allowed file extensions
ALLOWED_EXTENSIONS = {'json', 'csv', 'parquet', 'zip'}

def allowed_file(filename: str) -> bool:
    """
    Check if a file has an allowed extension.
    
    Args:
        filename: Name of the file to check
        
    Returns:
        True if file extension is allowed, False otherwise
    """
    return '.' in filename and filename.rsplit('.', 1)[1].lower() in ALLOWED_EXTENSIONS

@data_bp.route('/export', methods=['GET', 'POST'])
def export_data():
    """
    Export job data in various formats.
    """
    if request.method == 'POST':
        # Get export parameters
        format_type = request.form.get('format', 'json')
        limit = request.form.get('limit', type=int, default=0)
        compress = 'compress' in request.form
        
        # Create filters dict
        filters = {}
        if request.form.get('date_from'):
            filters['date_from'] = request.form.get('date_from')
        if request.form.get('date_to'):
            filters['date_to'] = request.form.get('date_to')
        if request.form.get('keywords'):
            filters['keywords'] = request.form.get('keywords')
        if request.form.get('company'):
            filters['company'] = request.form.get('company')
            
        # Get jobs
        job_repository = current_app.job_repository
        jobs = job_repository.get_filtered_jobs(filters, limit=limit)
        
        if not jobs:
            flash("No jobs found matching the filters", "warning")
            return redirect(url_for('data.export_data'))
            
        # Create a timestamp for the filename
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"job_export_{timestamp}.{format_type}"
        
        # Path where we'll save the export
        data_dir = Path(current_app.config['DATA_DIR'])
        export_dir = data_dir / "exports"
        export_dir.mkdir(exist_ok=True, parents=True)
        output_file = export_dir / filename
        
        # Convert jobs to dictionaries
        job_dicts = [job.to_dict() for job in jobs]
        
        # Export the data based on format type
        try:
            if format_type == 'json':
                with open(output_file, 'w') as f:
                    json.dump(job_dicts, f, default=str, indent=2)
            elif format_type == 'csv':
                df = pd.DataFrame(job_dicts)
                df.to_csv(output_file, index=False)
            elif format_type == 'parquet':
                df = pd.DataFrame(job_dicts)
                df.to_parquet(output_file, index=False)
            else:
                flash(f"Unsupported export format: {format_type}", "danger")
                return redirect(url_for('data.export_data'))
        except Exception as e:
            logger.error(f"Error exporting data: {e}")
            flash(f"Error exporting data: {str(e)}", "danger")
            return redirect(url_for('data.export_data'))
            
        logger.info(f"Exported {len(jobs)} jobs to {output_file}")
        
        # Compress if requested
        if compress:
            zip_filename = f"{filename}.zip"
            zip_path = export_dir / zip_filename
            
            with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
                zipf.write(output_file, arcname=filename)
                
            # Remove the original file
            output_file.unlink()
            output_file = zip_path
            filename = zip_filename
            
        flash(f"Data exported successfully: {filename}", "success")
        return redirect(url_for('data.download_file', filename=filename))
        
    # GET request - show export form
    return render_template('data/export.html')

@data_bp.route('/import', methods=['GET', 'POST'])
def import_data():
    """
    Import job data from file.
    """
    if request.method == 'POST':
        # Check if file was submitted
        if 'file' not in request.files:
            flash('No file part', 'danger')
            return redirect(request.url)
            
        file = request.files['file']
        if file.filename == '':
            flash('No selected file', 'danger')
            return redirect(request.url)
            
        if not file or not allowed_file(file.filename):
            flash('Invalid file type', 'danger')
            return redirect(request.url)
            
        # Process import parameters
        update_existing = 'update_existing' in request.form
        batch_size = request.form.get('batch_size', type=int, default=1000)
        
        # Save uploaded file to temporary location
        filename = secure_filename(file.filename)
        upload_folder = Path(current_app.config['UPLOAD_FOLDER'])
        file_path = upload_folder / filename
        file.save(file_path)
        
        # Process the file and import data
        try:
            jobs_data = []
            
            # Extract file extension
            ext = filename.rsplit('.', 1)[1].lower()
            
            # Handle zip files
            if ext == 'zip':
                with zipfile.ZipFile(file_path, 'r') as zipf:
                    # Get first file in the zip
                    inner_files = zipf.namelist()
                    if not inner_files:
                        raise ValueError("Zip file is empty")
                    
                    # Get first file with supported extension
                    inner_file = None
                    for fname in inner_files:
                        if '.' in fname and fname.rsplit('.', 1)[1].lower() in ['json', 'csv', 'parquet']:
                            inner_file = fname
                            break
                    
                    if not inner_file:
                        raise ValueError("No supported file found in zip")
                    
                    # Extract file to temp directory
                    temp_dir = upload_folder / "temp"
                    temp_dir.mkdir(exist_ok=True)
                    extracted_path = zipf.extract(inner_file, path=temp_dir)
                    
                    # Update file_path and extension
                    file_path = Path(extracted_path)
                    ext = inner_file.rsplit('.', 1)[1].lower()
            
            # Load data based on file type
            if ext == 'json':
                with open(file_path, 'r') as f:
                    jobs_data = json.load(f)
            elif ext == 'csv':
                df = pd.read_csv(file_path)
                jobs_data = df.to_dict('records')
            elif ext == 'parquet':
                df = pd.read_parquet(file_path)
                jobs_data = df.to_dict('records')
            else:
                raise ValueError(f"Unsupported file format: {ext}")
                
            # Check if data is valid
            if not jobs_data or not isinstance(jobs_data, list):
                raise ValueError("No valid job data found in file")
                
            logger.info(f"Loaded {len(jobs_data)} records from {file_path}")
            
            # Process jobs in batches
            job_repository = current_app.job_repository
            
            # Track success and error counts
            total_jobs = len(jobs_data)
            success_count = 0
            error_count = 0
            inserted_count = 0
            updated_count = 0
            
            # Process in batches
            from ...models.job import Job
            for i in range(0, total_jobs, batch_size):
                batch = jobs_data[i:i+batch_size]
                
                # Convert to Job objects
                job_objects = []
                for job_data in batch:
                    try:
                        # Check if required fields are present
                        if 'id' not in job_data:
                            error_count += 1
                            continue
                            
                        # Create Job object
                        job = Job(**job_data)
                        job_objects.append(job)
                        success_count += 1
                    except Exception as e:
                        logger.error(f"Error creating Job object: {e}")
                        error_count += 1
                
                # Bulk upsert jobs
                if job_objects:
                    try:
                        inserted, updated = job_repository.bulk_upsert_jobs(job_objects)
                        inserted_count += inserted
                        updated_count += updated
                    except Exception as e:
                        logger.error(f"Error upserting jobs: {e}")
                        error_count += len(job_objects)
                        success_count -= len(job_objects)
                        
            # Clean up
            if file_path.exists():
                file_path.unlink()
                
            # Show results
            flash(f"Data imported: {success_count} jobs processed, {inserted_count} inserted, {updated_count} updated, {error_count} errors", "success")
            return redirect(url_for('dashboard.index'))
            
        except Exception as e:
            logger.error(f"Error importing data: {e}")
            flash(f"Error importing data: {str(e)}", "danger")
            
            # Clean up
            if file_path.exists():
                file_path.unlink()
                
            return redirect(url_for('data.import_data'))
            
    # GET request - show import form
    return render_template('data/import.html')

@data_bp.route('/download/<path:filename>')
def download_file(filename):
    """
    Download a file.
    
    Args:
        filename: Name of the file to download
    """
    # Check file exists and is in allowed directories
    data_dir = Path(current_app.config['DATA_DIR'])
    backup_dir = Path(current_app.config['BACKUP_DIR'])
    export_dir = data_dir / "exports"
    
    # Security check - ensure filename doesn't try to navigate up the directory tree
    if '..' in filename:
        flash("Invalid filename", "danger")
        return redirect(url_for('dashboard.index'))
    
    # Try to find the file in exports directory first
    file_path = export_dir / filename
    if not file_path.exists():
        # Try in backup directory
        file_path = backup_dir / filename
        if not file_path.exists():
            flash(f"File not found: {filename}", "danger")
            return redirect(url_for('dashboard.index'))
    
    return send_file(
        str(file_path),
        as_attachment=True,
        download_name=filename
    )

@data_bp.route('/backup', methods=['GET', 'POST'])
def create_backup():
    """
    Create a backup of all data.
    """
    if request.method == 'POST':
        # Get backup parameters
        include_files = 'include_files' in request.form
        
        try:
            # Create a timestamp for the filename
            timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
            backup_filename = f"job_backup_{timestamp}.zip"
            
            # Backup directory
            backup_dir = Path(current_app.config['BACKUP_DIR'])
            backup_dir.mkdir(exist_ok=True, parents=True)
            backup_path = backup_dir / backup_filename
            
            # Data directory
            data_dir = Path(current_app.config['DATA_DIR'])
            
            # Create a zip file
            with zipfile.ZipFile(backup_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
                # Add a metadata file
                metadata = {
                    "backup_date": datetime.now().isoformat(),
                    "include_files": include_files,
                    "backup_type": "manual",
                }
                
                # Write metadata to a string and add to zip
                metadata_str = json.dumps(metadata, indent=2)
                zipf.writestr("metadata.json", metadata_str)
                
                # If we should include files, add them
                if include_files and data_dir.exists():
                    exports_dir = data_dir / "exports"
                    if exports_dir.exists():
                        for file_path in exports_dir.glob('*'):
                            if file_path.is_file():
                                # Add file to the backup
                                zipf.write(
                                    file_path,
                                    arcname=f"exports/{file_path.name}"
                                )
                
                # Create a database dump
                try:
                    # Get database connection details
                    db_dump_file = data_dir / f"db_dump_{timestamp}.sql"
                    
                    # Create database dump
                    job_repository = current_app.job_repository
                    db_schema = job_repository.db.schema
                    
                    db_dump_success = self._create_database_dump(
                        output_file=str(db_dump_file),
                        schema=db_schema
                    )
                    
                    if db_dump_success and db_dump_file.exists():
                        # Add dump file to the zip
                        zipf.write(
                            db_dump_file,
                            arcname="database/db_dump.sql"
                        )
                        # Remove the temporary dump file
                        db_dump_file.unlink()
                        logger.info("Database dump added to backup")
                    else:
                        logger.warning("Database dump failed or not found")
                        zipf.writestr(
                            "database/dump_status.txt",
                            "Database dump failed or not created"
                        )
                except Exception as e:
                    logger.error(f"Error during database dump: {e}")
                    # Add error message to the backup
                    zipf.writestr(
                        "database/dump_error.log",
                        f"Error: {str(e)}"
                    )
                    
            logger.info(f"Created backup: {backup_path}")
            
            flash(f"Backup created successfully: {backup_filename}", "success")
            return redirect(url_for('data.list_backups'))
            
        except Exception as e:
            logger.error(f"Error creating backup: {e}")
            flash(f"Error creating backup: {str(e)}", "danger")
            return redirect(url_for('data.create_backup'))
            
    # GET request - show backup form
    return render_template('data/backup.html')

def _create_database_dump(output_file: str, schema: str = "public") -> bool:
    """
    Create a database dump using pg_dump.
    
    Args:
        output_file: Path to output file
        schema: Database schema to dump
        
    Returns:
        True if successful, False otherwise
    """
    try:
        import subprocess
        
        # Get database connection details from environment
        host = os.environ.get("POSTGRES_HOST", "localhost")
        port = os.environ.get("POSTGRES_PORT", "5432")
        dbname = os.environ.get("POSTGRES_DB", "jobsdb")
        user = os.environ.get("POSTGRES_USER", "jobuser")
        
        # Try to get password from file first, then from environment
        password_file = os.environ.get("POSTGRES_PASSWORD_FILE")
        if password_file and os.path.exists(password_file):
            with open(password_file, 'r') as f:
                password = f.read().strip()
        else:
            password = os.environ.get("POSTGRES_PASSWORD", "devpassword")
        
        # Create the pg_dump command
        dump_cmd = [
            "pg_dump",
            f"--host={host}",
            f"--port={port}",
            f"--username={user}",
            f"--dbname={dbname}",
            "--format=plain",
            f"--schema={schema}",
            "--file", output_file
        ]
        
        # Set PGPASSWORD environment variable for authentication
        env = os.environ.copy()
        env["PGPASSWORD"] = password
        
        # Execute pg_dump
        logger.info(f"Creating database dump: {' '.join(dump_cmd)}")
        process = subprocess.run(
            dump_cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False
        )
        
        if process.returncode == 0:
            logger.info("Database dump created successfully")
            return True
        else:
            error_msg = process.stderr.decode('utf-8')
            logger.error(f"Failed to create database dump: {error_msg}")
            return False
            
    except Exception as e:
        logger.error(f"Error creating database dump: {e}")
        return False

@data_bp.route('/restore', methods=['GET', 'POST'])
def restore_backup():
    """
    Restore from a backup file.
    """
    if request.method == 'POST':
        # Get restore parameters
        backup_file = request.form.get('backup_file')
        restore_db = 'restore_db' in request.form
        restore_files = 'restore_files' in request.form
        
        if not backup_file:
            flash("No backup file selected", "danger")
            return redirect(url_for('data.list_backups'))
            
        try:
            # Log details about the restore operation
            logger.info(f"Starting restore from backup file: {backup_file}")
            
            # Full path to the backup file
            backup_dir = Path(current_app.config['BACKUP_DIR'])
            backup_path = backup_dir / backup_file
            
            if not backup_path.exists():
                flash(f"Backup file not found: {backup_file}", "danger")
                return redirect(url_for('data.list_backups'))
                
            # Create a temporary directory for extraction
            import tempfile
            import shutil
            
            with tempfile.TemporaryDirectory() as temp_dir_str:
                temp_dir = Path(temp_dir_str)
                
                # Extract the backup
                with zipfile.ZipFile(backup_path, 'r') as zipf:
                    # Extract all files
                    zipf.extractall(temp_dir)
                    
                    # Check for metadata
                    metadata_path = temp_dir / "metadata.json"
                    metadata = {}
                    if metadata_path.exists():
                        with open(metadata_path, 'r') as f:
                            metadata = json.load(f)
                            logger.info(f"Backup metadata: {metadata}")
                            
                    # Restore database if requested
                    if restore_db:
                        db_dump_path = temp_dir / "database" / "db_dump.sql"
                        if db_dump_path.exists():
                            # Restore database
                            db_restore_success = self._restore_database_from_dump(str(db_dump_path))
                            
                            if db_restore_success:
                                logger.info("Database restored successfully")
                                flash("Database restored successfully", "success")
                            else:
                                logger.error("Failed to restore database")
                                flash("Failed to restore database", "danger")
                        else:
                            logger.warning("No database dump found in the backup")
                            flash("No database dump found in the backup", "warning")
                            
                    # Restore files if requested
                    if restore_files:
                        exports_dir = temp_dir / "exports"
                        if exports_dir.exists() and exports_dir.is_dir():
                            # Create destination directory if it doesn't exist
                            data_dir = Path(current_app.config['DATA_DIR'])
                            dest_dir = data_dir / "exports"
                            dest_dir.mkdir(exist_ok=True, parents=True)
                            
                            # Copy files
                            file_count = 0
                            for file_path in exports_dir.glob('*'):
                                if file_path.is_file():
                                    dest_file = dest_dir / file_path.name
                                    shutil.copy2(file_path, dest_file)
                                    file_count += 1
                                    
                            logger.info(f"Restored {file_count} files")
                            flash(f"Restored {file_count} files", "success")
                        else:
                            logger.warning("No exports directory found in the backup")
                            flash("No exports directory found in the backup", "warning")
                            
            flash(f"Backup restoration completed for {backup_file}", "success")
            return redirect(url_for('dashboard.index'))
            
        except Exception as e:
            logger.error(f"Error restoring backup: {e}")
            flash(f"Error restoring backup: {str(e)}", "danger")
            return redirect(url_for('data.list_backups'))
            
    # GET request - show restore form with available backups
    backups = list_backups_files()
    return render_template('data/restore.html', backups=backups)

def _restore_database_from_dump(dump_file: str) -> bool:
    """
    Restore database from a SQL dump file.
    
    Args:
        dump_file: Path to SQL dump file
        
    Returns:
        True if successful, False otherwise
    """
    try:
        import subprocess
        
        # Get database connection details from environment
        host = os.environ.get("POSTGRES_HOST", "localhost")
        port = os.environ.get("POSTGRES_PORT", "5432")
        dbname = os.environ.get("POSTGRES_DB", "jobsdb")
        user = os.environ.get("POSTGRES_USER", "jobuser")
        
        # Try to get password from file first, then from environment
        password_file = os.environ.get("POSTGRES_PASSWORD_FILE")
        if password_file and os.path.exists(password_file):
            with open(password_file, 'r') as f:
                password = f.read().strip()
        else:
            password = os.environ.get("POSTGRES_PASSWORD", "devpassword")
        
        # Create the psql command
        restore_cmd = [
            "psql",
            f"--host={host}",
            f"--port={port}",
            f"--username={user}",
            f"--dbname={dbname}",
            "-f", dump_file
        ]
        
        # Set PGPASSWORD environment variable for authentication
        env = os.environ.copy()
        env["PGPASSWORD"] = password
        
        # Execute psql
        logger.info(f"Restoring database: {' '.join(restore_cmd)}")
        process = subprocess.run(
            restore_cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False
        )
        
        if process.returncode == 0:
            logger.info("Database restored successfully")
            return True
        else:
            error_msg = process.stderr.decode('utf-8')
            logger.error(f"Failed to restore database: {error_msg}")
            return False
            
    except Exception as e:
        logger.error(f"Error restoring database: {e}")
        return False

@data_bp.route('/backups')
def list_backups():
    """
    List available backups.
    """
    backups = list_backups_files()
    return render_template('data/backups.html', backups=backups)

def list_backups_files() -> List[Dict[str, Any]]:
    """
    Get list of available backup files with metadata.
    
    Returns:
        List of backup metadata dictionaries
    """
    backup_dir = Path(current_app.config['BACKUP_DIR'])
    backup_dir.mkdir(exist_ok=True, parents=True)
    
    backups = []
    
    for file_path in backup_dir.glob('*.zip'):
        if file_path.is_file() and file_path.name.startswith('job_backup_'):
            # Basic metadata
            backup_info = {
                'filename': file_path.name,
                'size': file_path.stat().st_size,
                'date': datetime.fromtimestamp(file_path.stat().st_mtime),
                'metadata': {}
            }
            
            # Try to extract metadata
            try:
                with zipfile.ZipFile(file_path, 'r') as zipf:
                    if 'metadata.json' in zipf.namelist():
                        with zipf.open('metadata.json') as f:
                            metadata = json.load(f)
                            backup_info['metadata'] = metadata
            except Exception as e:
                logger.error(f"Error reading backup metadata: {e}")
                
            backups.append(backup_info)
    
    # Sort by date, newest first
    backups.sort(key=lambda x: x['date'], reverse=True)
    
    return backups 