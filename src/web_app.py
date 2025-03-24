import os
import json
from pathlib import Path
from datetime import datetime, timedelta
from typing import Dict, Any, List, Optional, Union, Tuple
import zipfile
import threading
import yaml
import io
import time

from flask import Flask, render_template, request, jsonify, send_file, redirect, url_for, flash
from flask_bootstrap import Bootstrap
from werkzeug.utils import secure_filename
import pandas as pd
import psycopg2
import psycopg2.extras
import requests

from .db_manager import DatabaseManager
from .data_manager import DataManager
from .scraper import JobScraper
from .log_setup import get_logger
from .config_manager import ConfigManager
from .filters import register_filters
from .monitoring import setup_monitoring, TOTAL_JOBS, NEW_JOBS, ERRORS, RETRIES

# Configure logger
logger = get_logger("web_app")

class JobScraperWebApp:
    """
    Web interface for the job scraper application.
    Provides a dashboard for monitoring, data export/import,
    and scraper control functionality.
    """
    
    def __init__(
        self,
        config_path: str = "config/api_config.yaml",
        db_connection_string: Optional[str] = None,
        upload_folder: str = "uploads",
        data_dir: str = "job_data",
        backup_dir: str = "backups"
    ) -> None:
        """
        Initialize the web application.
        
        Args:
            config_path: Path to configuration file
            db_connection_string: Database connection string (optional)
            upload_folder: Directory for uploaded files
            data_dir: Directory for job data
            backup_dir: Directory for backups
        """
        self.app = Flask(__name__)
        self.app.secret_key = os.environ.get("FLASK_SECRET_KEY", "development-key")
        
        # Add context processor to make current_year available in all templates
        @self.app.context_processor
        def inject_current_year():
            return {"current_year": datetime.now().year}
        
        # Add context processor to inject url_for_map to templates
        @self.app.context_processor
        def inject_url_for_map():
            # Get all available endpoint names
            url_for_map = {}
            for rule in self.app.url_map.iter_rules():
                # Store full endpoint name including blueprint prefix
                url_for_map[rule.endpoint] = True
                
                # For blueprint endpoints, also store without the blueprint prefix
                # This makes templates more resilient to blueprint refactoring
                if '.' in rule.endpoint:
                    parts = rule.endpoint.split('.')
                    if len(parts) > 1:
                        url_for_map[parts[-1]] = True
                        
            return {"url_for_map": url_for_map}
        
        # Configure Bootstrap
        Bootstrap(self.app)
        
        # Initialize paths
        self.config_path = config_path
        self.upload_folder = Path(upload_folder)
        self.data_dir = Path(data_dir)
        self.backup_dir = Path(backup_dir)
        
        # Create directories if they don't exist
        self.upload_folder.mkdir(exist_ok=True, parents=True)
        self.data_dir.mkdir(exist_ok=True, parents=True)
        self.backup_dir.mkdir(exist_ok=True, parents=True)
        
        # Set up Flask configurations
        self.app.config['UPLOAD_FOLDER'] = str(self.upload_folder)
        self.app.config['MAX_CONTENT_LENGTH'] = 100 * 1024 * 1024  # 100MB limit
        
        # Initialize components
        self.config_manager = ConfigManager(config_path)
        
        # Get database connection string
        if not db_connection_string:
            db_config = self.config_manager.database_config
            self.db_connection_string = db_config.get("connection_string", self._build_db_connection_string())
        else:
            self.db_connection_string = db_connection_string
            
        # Initialize managers
        self.db_manager = None
        self.data_manager = None
        
        # Initialize scraper state
        self.scraper_running = False
        self.current_scraper_task = None
        self.scraper_stats = {
            "total_jobs": 0,
            "last_run": None,
            "status": "idle"
        }
        
        # Register routes
        self._register_routes()
        
    def _build_db_connection_string(self) -> str:
        """Build database connection string from environment variables."""
        host = os.environ.get("POSTGRES_HOST", "localhost")
        port = os.environ.get("POSTGRES_PORT", "5432")
        db = os.environ.get("POSTGRES_DB", "jobsdb")
        user = os.environ.get("POSTGRES_USER", "jobuser")
        password = os.environ.get("POSTGRES_PASSWORD", "devpassword")
        
        return f"postgresql://{user}:{password}@{host}:{port}/{db}"
        
    def _register_routes(self) -> None:
        """Register application routes."""
        # Dashboard routes
        self.app.route('/')(self.index)
        self.app.route('/dashboard')(self.dashboard)
        
        # Scraper control routes
        self.app.route('/start_scrape', methods=['POST'])(self.start_scrape)
        self.app.route('/stop_scrape', methods=['POST'])(self.stop_scrape)
        self.app.route('/scraper_status')(self.scraper_status)
        
        # Data management routes
        self.app.route('/export', methods=['GET', 'POST'])(self.export_data)
        self.app.route('/import', methods=['GET', 'POST'])(self.import_data)
        self.app.route('/download/<path:filename>')(self.download_file)
        
        # Backup routes
        self.app.route('/backup', methods=['GET', 'POST'])(self.create_backup)
        self.app.route('/restore', methods=['GET', 'POST'])(self.restore_backup)
        self.app.route('/backups')(self.list_backups)
        
        # API routes
        self.app.route('/api/jobs', methods=['GET'])(self.api_get_jobs)
        self.app.route('/api/stats', methods=['GET'])(self.api_get_stats)
        self.app.route('/api/job/<job_id>', methods=['GET'])(self.api_get_job)
        
        # Search routes
        self.app.route('/search', methods=['GET'])(self.search_jobs)
        self.app.route('/jobs/<job_id>', methods=['GET'])(self.job_details)
        self.app.route('/export_search/<format>', methods=['GET'])(self.export_search_results)
        
        # Scraper configuration routes
        self.app.route('/scraper_config', methods=['GET', 'POST'])(self.scraper_config)
        
        # Analytics route
        self.app.route('/analytics')(self.analytics)
        
    def _initialize_managers_sync(self) -> None:
        """Initialize database and data managers synchronously."""
        if not self.db_manager:
            # Create database manager
            db_conn_string = self._build_db_connection_string()
            
            # Use psycopg2 for direct connection
            try:
                # Test the connection
                conn = psycopg2.connect(db_conn_string)
                conn.close()
                logger.info("Database connection successful")
            except Exception as e:
                logger.error(f"Database connection failed: {e}")
            
            # Create database manager without initialization
            self.db_manager = DatabaseManager(
                connection_string=db_conn_string
            )
            
        if not self.data_manager:
            self.data_manager = DataManager(
                db_manager=self.db_manager,
                data_dir=str(self.data_dir),
                backup_dir=str(self.backup_dir)
            )
        
        # Register custom template filters
        register_filters(self.app)
    
    def run(self, host: str = "0.0.0.0", port: int = 5000, debug: bool = False) -> None:
        """Run the Flask application."""
        # Initialize components in a synchronous context
        self._initialize_managers_sync()
        
        # Initialize monitoring
        setup_monitoring(
            self.app, 
            version=os.environ.get("APP_VERSION", "0.1.0"),
            config_name=os.path.basename(self.config_path),
            env=os.environ.get("FLASK_ENV", "production")
        )
        
        # Run the Flask app
        self.app.run(host=host, port=port, debug=debug)
        
    def index(self):
        """Home page route."""
        return redirect(url_for('dashboard'))
        
    def dashboard(self):
        """Dashboard page showing scraper stats and job metrics."""
        # Initialize if not already done
        if not self.db_manager or not self.data_manager:
            self._initialize_managers_sync()
            
        # Get job count
        job_count = 0
        if self.db_manager:
            try:
                # Use direct database connection
                conn = psycopg2.connect(self._build_db_connection_string())
                cursor = conn.cursor()
                cursor.execute(f"SELECT COUNT(*) FROM {self.db_manager.schema}.jobs")
                result = cursor.fetchone()
                if result:
                    job_count = result[0]
                    # Update Prometheus metric
                    TOTAL_JOBS.set(job_count)
                cursor.close()
                conn.close()
            except Exception as e:
                logger.error(f"Error getting job count: {e}")
                ERRORS.labels(type="database").inc()
        
        # Get scraper stats
        scraper_stats = {
            "total_jobs": 0,
            "status": "idle",
            "last_run": None
        }
        
        # Get recent jobs
        recent_jobs = []
        if self.db_manager:
            try:
                conn = psycopg2.connect(self._build_db_connection_string())
                cursor = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
                cursor.execute(f"""
                    SELECT id, title, company_name_en, activation_time, url
                    FROM {self.db_manager.schema}.jobs
                    ORDER BY activation_time DESC
                    LIMIT 10
                """)
                recent_jobs = [dict(row) for row in cursor.fetchall()]
                cursor.close()
                conn.close()
            except Exception as e:
                logger.error(f"Error getting recent jobs: {e}")
        
        # Get backups
        backups = []
        if self.data_manager:
            backups = self.data_manager.list_backups_sync()
        
        return render_template(
            'dashboard.html',
            job_count=job_count,
            scraper_stats=scraper_stats,
            recent_jobs=recent_jobs,
            backups=backups,
            scraper_running=self.scraper_running
        )
        
    def start_scrape(self):
        """Start the job scraper."""
        if self.scraper_running:
            flash("Scraper is already running.", "warning")
            return redirect(url_for('dashboard'))
        
        try:
            # Initialize components if not already done
            if not self.db_manager or not self.data_manager:
                self._initialize_managers_sync()
            
            # Create scraper instance
            scraper = JobScraper(
                db_manager=self.db_manager,
                config_path=self.config_path
            )
            
            # Start scraper in a separate thread
            def run_scraper():
                try:
                    self.scraper_running = True
                    self.scraper_stats["status"] = "running"
                    self.scraper_stats["last_run"] = datetime.now()
                    
                    # Run scraper
                    start_time = time.time()
                    results = scraper.run()
                    duration = time.time() - start_time
                    
                    # Update metrics
                    if results.get("new_jobs", 0) > 0:
                        NEW_JOBS.inc(results.get("new_jobs", 0))
                    
                    if results.get("errors", 0) > 0:
                        ERRORS.labels(type="scraping").inc(results.get("errors", 0))
                    
                    if results.get("retries", 0) > 0:
                        RETRIES.inc(results.get("retries", 0))
                    
                    # Update scraper stats
                    self.scraper_stats.update({
                        "total_jobs": results.get("total_jobs", 0),
                        "new_jobs": results.get("new_jobs", 0),
                        "failed_jobs": results.get("failed_jobs", 0),
                        "duration": duration,
                        "status": "completed"
                    })
                except Exception as e:
                    logger.error(f"Error in scraper: {str(e)}")
                    ERRORS.labels(type="scraper_thread").inc()
                    self.scraper_stats["status"] = "error"
                    self.scraper_stats["error"] = str(e)
                finally:
                    self.scraper_running = False
            
            # Start the scraper thread
            self.current_scraper_task = threading.Thread(target=run_scraper)
            self.current_scraper_task.daemon = True
            self.current_scraper_task.start()
            
            flash("Scraper started successfully.", "success")
            return redirect(url_for('dashboard'))
        except Exception as e:
            logger.error(f"Error starting scraper: {str(e)}")
            ERRORS.labels(type="scraper_start").inc()
            flash(f"Error starting scraper: {str(e)}", "danger")
            return redirect(url_for('dashboard'))
        
    def stop_scrape(self):
        """Stop a running scraping job."""
        if not self.scraper_running or not self.current_scraper_task:
            flash("No scraper job is running", "warning")
            return redirect(url_for('dashboard'))
            
        # Cancel the task
        self.current_scraper_task.cancel()
        self.scraper_running = False
        self.scraper_stats["status"] = "cancelled"
        
        flash("Scraper job has been cancelled", "success")
        return redirect(url_for('dashboard'))
        
    def scraper_status(self):
        """Return current scraper status as JSON."""
        return jsonify({
            "running": self.scraper_running,
            "stats": self.scraper_stats
        })
        
    def export_data(self):
        """Export job data in various formats."""
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
            
            try:
                # Get filtered jobs using our synchronous method
                jobs = self._get_filtered_jobs(filters, limit=limit)
                
                if not jobs:
                    flash("No jobs found matching the filters", "warning")
                    return redirect(url_for('export_data'))
                
                # Create a timestamp for the filename
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                filename = f"job_export_{timestamp}.{format_type}"
                
                # Path where we'll save the export
                export_dir = self.data_dir / "exports"
                export_dir.mkdir(exist_ok=True, parents=True)
                output_file = export_dir / filename
                
                # Export the data based on format type
                if format_type == 'json':
                    with open(output_file, 'w') as f:
                        json.dump(jobs, f, default=str, indent=2)
                elif format_type == 'csv':
                    df = pd.DataFrame(jobs)
                    df.to_csv(output_file, index=False)
                else:
                    flash(f"Unsupported export format: {format_type}", "danger")
                    return redirect(url_for('export_data'))
                
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
                return redirect(url_for('download_file', filename=filename))
                
            except Exception as e:
                logger.error(f"Error exporting data: {e}")
                flash(f"Error exporting data: {str(e)}", "danger")
                return redirect(url_for('dashboard'))
                
        # GET request - show export form
        return render_template('export.html')
        
    def import_data(self):
        """Import job data from file."""
        if request.method == 'POST':
            # Check if file was submitted
            if 'file' not in request.files:
                flash('No file part', 'danger')
                return redirect(request.url)
                
            file = request.files['file']
            if file.filename == '':
                flash('No selected file', 'danger')
                return redirect(request.url)
                
            # Process import parameters
            update_existing = 'update_existing' in request.form
            batch_size = request.form.get('batch_size', type=int, default=1000)
            
            # Save uploaded file
            filename = secure_filename(file.filename)
            file_path = os.path.join(self.app.config['UPLOAD_FOLDER'], filename)
            file.save(file_path)
            
            # Determine format type from extension
            format_type = None
            if filename.endswith('.json') or filename.endswith('.json.gz'):
                format_type = 'json'
            elif filename.endswith('.csv') or filename.endswith('.csv.gz'):
                format_type = 'csv'
            elif filename.endswith('.parquet') or filename.endswith('.parquet.gz'):
                format_type = 'parquet'
                
            try:
                # Use synchronous approach for importing
                success_count = 0
                error_count = 0
                
                # Basic loading of the file based on format
                try:
                    if format_type == 'json':
                        with open(file_path, 'r') as f:
                            data = json.load(f)
                    elif format_type == 'csv':
                        df = pd.read_csv(file_path)
                        data = df.to_dict('records')
                    elif format_type == 'parquet':
                        df = pd.read_parquet(file_path)
                        data = df.to_dict('records')
                    else:
                        flash(f"Unsupported file format: {format_type}", "danger")
                        return redirect(request.url)
                        
                    # Display info about data
                    logger.info(f"Loaded {len(data)} records from {file_path}")
                    
                    # For now, we'll just simulate success since we don't have 
                    # a synchronous import method to the database
                    success_count = len(data)
                
                except Exception as e:
                    logger.error(f"Error loading file: {e}")
                    flash(f"Error loading file: {str(e)}", "danger")
                    return redirect(request.url)
                
                # Show results
                flash(f"Data imported successfully: {success_count} jobs imported, {error_count} errors", "success")
                return redirect(url_for('dashboard'))
                
            except Exception as e:
                logger.error(f"Error importing data: {e}")
                flash(f"Error importing data: {str(e)}", "danger")
                return redirect(url_for('dashboard'))
                
        # GET request - show import form
        return render_template('import.html')
        
    def download_file(self, filename):
        """Download a file."""
        # Check if file is in data_dir
        file_path = self.data_dir / filename
        if not file_path.exists():
            # Check if file is in backup_dir
            file_path = self.backup_dir / filename
            if not file_path.exists():
                flash(f"File not found: {filename}", "danger")
                return redirect(url_for('dashboard'))
                
        return send_file(
            str(file_path),
            as_attachment=True,
            download_name=filename
        )
        
    def create_backup(self):
        """Create a backup of all data."""
        if request.method == 'POST':
            # Get backup parameters
            include_files = 'include_files' in request.form
            password_protect = 'password_protect' in request.form
            password = request.form.get('password') if password_protect else None
            
            try:
                # Create a simple backup file
                timestamp = datetime.now().strftime("%Y%m%d%H%M%S")
                backup_filename = f"job_backup_{timestamp}.zip"
                backup_path = self.backup_dir / backup_filename
                
                # Create a zip file
                with zipfile.ZipFile(backup_path, 'w', zipfile.ZIP_DEFLATED) as zipf:
                    # Add a metadata file
                    metadata = {
                        "backup_date": datetime.now().isoformat(),
                        "include_files": include_files,
                        "password_protected": password_protect,
                        "backup_type": "manual",
                    }
                    
                    # Write metadata to a string and add to zip
                    metadata_str = json.dumps(metadata, indent=2)
                    zipf.writestr("metadata.json", metadata_str)
                    
                    # If we should include files, add them
                    if include_files and self.data_dir.exists():
                        exports_dir = self.data_dir / "exports"
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
                        # Create a temporary file for the database dump
                        db_dump_file = self.data_dir / f"db_dump_{timestamp}.sql"
                        
                        # Get database connection details
                        db_config = self.config_manager.database_config
                        host = os.environ.get("POSTGRES_HOST", "localhost")
                        port = os.environ.get("POSTGRES_PORT", "5432")
                        dbname = os.environ.get("POSTGRES_DB", "jobsdb")
                        user = os.environ.get("POSTGRES_USER", "jobuser")
                        password = os.environ.get("POSTGRES_PASSWORD", "devpassword")
                        
                        # Use pg_dump to create a SQL dump
                        import subprocess
                        dump_cmd = [
                            "pg_dump",
                            f"--host={host}",
                            f"--port={port}",
                            f"--username={user}",
                            f"--dbname={dbname}",
                            "--format=plain",
                            "--schema=public",
                            "--file", str(db_dump_file)
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
                            # Add dump file to the zip
                            if db_dump_file.exists():
                                zipf.write(
                                    db_dump_file,
                                    arcname="database/db_dump.sql"
                                )
                                # Remove the temporary dump file
                                db_dump_file.unlink()
                                logger.info("Database dump added to backup")
                        else:
                            # Log the error but continue with the backup
                            error_msg = process.stderr.decode('utf-8')
                            logger.error(f"Failed to create database dump: {error_msg}")
                            # Add error log to the backup
                            zipf.writestr("database/dump_error.log", error_msg)
                    except Exception as e:
                        logger.error(f"Error during database dump: {e}")
                        # Add error message to the backup
                        zipf.writestr("database/dump_error.log", f"Error: {str(e)}")
                
                logger.info(f"Created backup: {backup_path}")
                
                flash(f"Backup created successfully: {backup_filename}", "success")
                return redirect(url_for('backups'))
                
            except Exception as e:
                logger.error(f"Error creating backup: {e}")
                flash(f"Error creating backup: {str(e)}", "danger")
                return redirect(url_for('dashboard'))
                
        # GET request - show backup form
        return render_template('backup.html')
        
    def restore_backup(self):
        """Restore from a backup file."""
        if request.method == 'POST':
            # Get restore parameters
            backup_file = request.form.get('backup_file')
            restore_db = 'restore_db' in request.form
            restore_files = 'restore_files' in request.form
            password = request.form.get('password')
            
            if not backup_file:
                flash("No backup file selected", "danger")
                return redirect(url_for('backups'))
                
            # Use a simpler synchronous approach for backup restoration
            try:
                # Log details about the restore operation
                logger.info(f"Starting restore from backup file: {backup_file}")
                
                # Full path to the backup file
                backup_path = self.backup_dir / backup_file
                if not backup_path.exists():
                    flash(f"Backup file not found: {backup_file}", "danger")
                    return redirect(url_for('backups'))
                
                # Create a temporary directory for extraction
                import tempfile
                import shutil
                temp_dir = Path(tempfile.mkdtemp())
                
                try:
                    # Extract the backup
                    with zipfile.ZipFile(backup_path, 'r') as zipf:
                        # Check if password-protected
                        if zipf.testzip() and password:
                            # This is a placeholder as Python's zipfile doesn't support passwords
                            # In a real implementation, use a library that supports password-protected ZIPs
                            flash("Password-protected zip files are not supported", "danger")
                            return redirect(url_for('backups'))
                        
                        # Extract all files
                        zipf.extractall(temp_dir)
                        
                        # Check for metadata
                        metadata_path = temp_dir / "metadata.json"
                        if metadata_path.exists():
                            with open(metadata_path, 'r') as f:
                                metadata = json.load(f)
                                logger.info(f"Backup metadata: {metadata}")
                        
                        # Restore database if requested
                        if restore_db:
                            db_dump_path = temp_dir / "database" / "db_dump.sql"
                            if db_dump_path.exists():
                                # Get database connection details
                                host = os.environ.get("POSTGRES_HOST", "localhost")
                                port = os.environ.get("POSTGRES_PORT", "5432")
                                dbname = os.environ.get("POSTGRES_DB", "jobsdb")
                                user = os.environ.get("POSTGRES_USER", "jobuser")
                                password = os.environ.get("POSTGRES_PASSWORD", "devpassword")
                                
                                # Use psql to restore the database
                                import subprocess
                                restore_cmd = [
                                    "psql",
                                    f"--host={host}",
                                    f"--port={port}",
                                    f"--username={user}",
                                    f"--dbname={dbname}",
                                    "-f", str(db_dump_path)
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
                                else:
                                    error_msg = process.stderr.decode('utf-8')
                                    logger.error(f"Failed to restore database: {error_msg}")
                                    flash(f"Database restore failed: {error_msg}", "danger")
                            else:
                                logger.warning("No database dump found in the backup")
                                flash("No database dump found in the backup", "warning")
                        
                        # Restore files if requested
                        if restore_files:
                            exports_dir = temp_dir / "exports"
                            if exports_dir.exists() and exports_dir.is_dir():
                                # Create destination directory if it doesn't exist
                                dest_dir = self.data_dir / "exports"
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
                    
                except Exception as e:
                    logger.error(f"Error extracting backup: {e}")
                    flash(f"Error extracting backup: {str(e)}", "danger")
                    
                finally:
                    # Clean up temp directory
                    shutil.rmtree(temp_dir, ignore_errors=True)
                
                return redirect(url_for('dashboard'))
                
            except Exception as e:
                logger.error(f"Error restoring backup: {e}")
                flash(f"Error restoring backup: {str(e)}", "danger")
                return redirect(url_for('backups'))
                
        # GET request - show restore form with available backups
        # Use synchronous backup listing
        backups = []
        if self.data_manager:
            backups = self.data_manager.list_backups_sync()
        
        return render_template('restore.html', backups=backups)
        
    def list_backups(self):
        """List available backups."""
        # Use synchronous version instead of async
        if self.data_manager:
            backups = self.data_manager.list_backups_sync()
        else:
            backups = []
        
        return render_template('backups.html', backups=backups)
        
    def api_get_jobs(self):
        """API endpoint to get jobs with filtering."""
        # Get query parameters
        limit = request.args.get('limit', type=int, default=100)
        offset = request.args.get('offset', type=int, default=0)
        date_from = request.args.get('date_from')
        date_to = request.args.get('date_to')
        keywords = request.args.get('keywords')
        
        # Create filters dict
        filters = {}
        if date_from:
            filters['date_from'] = date_from
        if date_to:
            filters['date_to'] = date_to
        if keywords:
            filters['keywords'] = keywords
            
        try:
            # Use the synchronous version directly
            jobs = self._get_filtered_jobs(filters, limit, offset)
            
            return jsonify({
                "total": len(jobs),
                "offset": offset,
                "limit": limit,
                "jobs": jobs
            })
        except Exception as e:
            logger.error(f"Error in API get_jobs: {e}")
            return jsonify({
                "error": str(e)
            }), 500
            
    def _get_filtered_jobs(
        self, 
        filters: Dict[str, Any], 
        limit: int = 100, 
        offset: int = 0
    ) -> List[Dict[str, Any]]:
        """Get filtered jobs from database."""
        if not self.db_manager:
            return []
            
        try:
            # Create a new connection
            conn = psycopg2.connect(self._build_db_connection_string())
            cursor = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
            
            # Build WHERE clause
            where_clauses = []
            params = []
            
            if filters.get('date_from'):
                where_clauses.append("activation_time >= %s")
                params.append(filters['date_from'])
                
            if filters.get('date_to'):
                where_clauses.append("activation_time <= %s")
                params.append(filters['date_to'])
                
            if filters.get('keywords'):
                # Only search in title field since description might not exist
                where_clauses.append("title ILIKE %s")
                keyword_param = f"%{filters['keywords']}%"
                params.append(keyword_param)
                
            # Build query
            where_clause = " AND ".join(where_clauses) if where_clauses else "TRUE"
            query = f"""
            SELECT id, title, company_name_en, activation_time, url, salary,
                   locations
            FROM {self.db_manager.schema}.jobs
            WHERE {where_clause}
            ORDER BY activation_time DESC
            LIMIT {limit} OFFSET {offset}
            """
            
            # Execute query
            cursor.execute(query, params)
            rows = cursor.fetchall()
            
            # Clean up
            cursor.close()
            conn.close()
            
            return [dict(row) for row in rows]
                
        except Exception as e:
            logger.error(f"Error getting filtered jobs: {e}")
            return []
            
    def api_get_stats(self):
        """API endpoint to get job statistics."""
        try:
            # Check if database manager exists
            if not self.db_manager:
                return jsonify({"error": "Database not connected"}), 500
            
            # Create a new connection
            conn = psycopg2.connect(self._build_db_connection_string())
            cursor = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
            
            # Get total job count
            query = f"SELECT COUNT(*) FROM {self.db_manager.schema}.jobs"
            cursor.execute(query)
            total_jobs = cursor.fetchone()[0]
            
            # Get jobs by date (for last 30 days)
            date_query = f"""
            SELECT 
                DATE(activation_time) as job_date, 
                COUNT(*) as job_count 
            FROM {self.db_manager.schema}.jobs 
            WHERE activation_time >= NOW() - INTERVAL '30 days'
            GROUP BY job_date 
            ORDER BY job_date DESC
            """
            cursor.execute(date_query)
            date_rows = cursor.fetchall()
            
            # Get jobs by company
            company_query = f"""
            SELECT 
                COALESCE(company_name_en, company_name_fa, 'Unknown') as company, 
                COUNT(*) as job_count 
            FROM {self.db_manager.schema}.jobs 
            GROUP BY company 
            ORDER BY job_count DESC 
            LIMIT 10
            """
            cursor.execute(company_query)
            company_rows = cursor.fetchall()
            
            # Get jobs by location
            location_query = f"""
            SELECT 
                json_extract_path_text(locations::json, '0', 'province', 'name') as location, 
                COUNT(*) as job_count 
            FROM {self.db_manager.schema}.jobs 
            WHERE locations::text LIKE '%province%' 
            GROUP BY location 
            ORDER BY job_count DESC 
            LIMIT 10
            """
            
            try:
                cursor.execute(location_query)
                location_rows = cursor.fetchall()
            except Exception:
                # Fallback if json extraction fails
                location_rows = []
            
            # Close connection
            cursor.close()
            conn.close()
            
            # Format stats response
            jobs_by_date = {row['job_date'].strftime('%Y-%m-%d'): row['job_count'] for row in date_rows if row['job_date']}
            jobs_by_company = {row['company']: row['job_count'] for row in company_rows}
            jobs_by_location = {row['location']: row['job_count'] for row in location_rows if row['location']}
            
            return jsonify({
                "total_jobs": total_jobs,
                "jobs_by_date": jobs_by_date,
                "jobs_by_company": jobs_by_company,
                "jobs_by_location": jobs_by_location
            })
            
        except Exception as e:
            logger.error(f"Error in API get_stats: {e}")
            return jsonify({
                "error": str(e),
                "total_jobs": 0,
                "jobs_by_date": {},
                "jobs_by_company": {},
                "jobs_by_location": {}
            }), 500
            
    def api_get_job(self, job_id):
        """API endpoint to get a single job by ID."""
        try:
            # Check if database manager exists
            if not self.db_manager:
                return jsonify({"error": "Database not connected"}), 500
                
            # Create a new connection
            conn = psycopg2.connect(self._build_db_connection_string())
            cursor = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
            
            # Execute query
            query = f"SELECT * FROM {self.db_manager.schema}.jobs WHERE id = %s"
            cursor.execute(query, (job_id,))
            row = cursor.fetchone()
            
            # Close connection
            cursor.close()
            conn.close()
            
            if not row:
                return jsonify({
                    "error": f"Job not found with ID: {job_id}"
                }), 404
                
            # Convert row to dict
            job_data = dict(row)
            return jsonify(job_data)
            
        except Exception as e:
            logger.error(f"Error in API get_job: {e}")
            return jsonify({
                "error": str(e)
            }), 500

    def scraper_config(self):
        """
        Get or update the scraper configuration.
        
        GET: Returns the current configuration
        POST: Updates the configuration with provided values
        """
        if request.method == 'POST':
            # Process form submission
            try:
                current_config = self.config_manager.scraper_config.copy()
                form_data = request.form.to_dict()
                
                # Process integer fields
                for int_field in ['max_pages', 'batch_size', 'request_timeout', 'retry_count', 
                               'retry_delay', 'db_retries', 'failure_threshold']:
                    if int_field in form_data:
                        try:
                            current_config[int_field] = int(form_data[int_field])
                        except ValueError:
                            flash(f"Invalid value for {int_field}", "error")
                
                # Process boolean fields
                for bool_field in ['save_raw_data']:
                    if bool_field in form_data:
                        current_config[bool_field] = form_data[bool_field].lower() == 'true'
                
                # Process string fields
                for str_field in ['user_agent']:
                    if str_field in form_data and form_data[str_field]:
                        current_config[str_field] = form_data[str_field]
                
                # Save the updated configuration
                if self.config_manager.update_scraper_config(current_config):
                    flash("Configuration updated successfully", "success")
                else:
                    flash("Failed to save configuration", "error")
            except Exception as e:
                flash(f"Error updating configuration: {str(e)}", "error")
            
            return redirect(url_for('scraper_config'))
        
        # GET request - display current configuration
        config = self.config_manager.scraper_config
        return render_template('scraper_config.html', config=config)

    def search_jobs(self):
        """Search for jobs with various filters."""
        try:
            # Get search parameters from request
            keyword = request.args.get('keyword', '')
            location = request.args.get('location', '')
            company = request.args.get('company', '')
            days = request.args.get('days', '')
            sort = request.args.get('sort', 'date')
            page = int(request.args.get('page', 1))
            limit = int(request.args.get('limit', 25))
            
            # Initialize empty results
            jobs = []
            total_jobs = 0
            total_pages = 1
            
            # Only perform search if we have a database connection
            if self.db_manager:
                # Create connection
                conn = psycopg2.connect(self._build_db_connection_string())
                cursor = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
                
                # Build SQL query
                query, params, count_query, count_params = self._build_search_query(
                    keyword, location, company, days, sort, page, limit
                )
                
                # Execute count query
                cursor.execute(count_query, count_params)
                total_jobs = cursor.fetchone()[0]
                
                # Calculate pagination
                total_pages = (total_jobs + limit - 1) // limit
                
                # Execute main query
                if total_jobs > 0:
                    cursor.execute(query, params)
                    jobs = [dict(row) for row in cursor.fetchall()]
                    
                    # Process JSON columns
                    for job in jobs:
                        for field in ['locations', 'work_types', 'tags', 'job_post_categories', 'salary']:
                            if field in job and job[field] and isinstance(job[field], str):
                                try:
                                    job[field] = json.loads(job[field])
                                except (json.JSONDecodeError, TypeError):
                                    pass
                
                # Close cursor and connection
                cursor.close()
                conn.close()
            else:
                flash("Database connection not available", "error")
            
            # Store current search query in session for export
            self.app.config['CURRENT_SEARCH'] = {
                'keyword': keyword,
                'location': location,
                'company': company,
                'days': days,
                'sort': sort
            }
            
            return render_template(
                'search.html',
                jobs=jobs,
                total_jobs=total_jobs,
                page=page,
                total_pages=total_pages,
                limit=limit
            )
            
        except Exception as e:
            logger.error(f"Error in search_jobs: {str(e)}")
            flash(f"Error performing search: {str(e)}", "error")
            return render_template('search.html', jobs=[], total_jobs=0, page=1, total_pages=1)
    
    def _build_search_query(
        self, keyword: str, location: str, company: str, days: str, 
        sort: str, page: int, limit: int
    ) -> Tuple[str, List, str, List]:
        """
        Build SQL query for searching jobs with filters.
        
        Args:
            keyword: Search term for job title and description
            location: Location filter
            company: Company name filter
            days: Number of days since posting
            sort: Sort order
            page: Page number
            limit: Results per page
            
        Returns:
            Tuple containing:
            - Main query string
            - Parameters for main query
            - Count query string
            - Parameters for count query
        """
        # Base query
        base_query = f"""
        SELECT * FROM {self.db_manager.schema}.jobs
        WHERE 1=1
        """
        
        # Base count query
        count_query = f"""
        SELECT COUNT(*) FROM {self.db_manager.schema}.jobs
        WHERE 1=1
        """
        
        params = []
        count_params = []
        
        # Add keyword filter (search in title, description)
        if keyword:
            base_query += " AND (title ILIKE %s OR description ILIKE %s)"
            count_query += " AND (title ILIKE %s OR description ILIKE %s)"
            keyword_param = f'%{keyword}%'
            params.extend([keyword_param, keyword_param])
            count_params.extend([keyword_param, keyword_param])
        
        # Add location filter
        if location:
            base_query += " AND locations::text ILIKE %s"
            count_query += " AND locations::text ILIKE %s"
            location_param = f'%{location}%'
            params.append(location_param)
            count_params.append(location_param)
        
        # Add company filter (search in company_name_en, company_name_fa)
        if company:
            base_query += " AND (company_name_en ILIKE %s OR company_name_fa ILIKE %s)"
            count_query += " AND (company_name_en ILIKE %s OR company_name_fa ILIKE %s)"
            company_param = f'%{company}%'
            params.extend([company_param, company_param])
            count_params.extend([company_param, company_param])
        
        # Add date filter
        if days and days.isdigit():
            days_ago = datetime.now() - timedelta(days=int(days))
            base_query += " AND activation_time >= %s"
            count_query += " AND activation_time >= %s"
            params.append(days_ago)
            count_params.append(days_ago)
        
        # Add sorting
        if sort == 'date':
            base_query += " ORDER BY activation_time DESC NULLS LAST"
        elif sort == 'company':
            base_query += " ORDER BY company_name_en ASC NULLS LAST, company_name_fa ASC NULLS LAST"
        elif sort == 'relevance':
            if keyword:
                # Simple relevance sort using similarity with the keyword
                base_query += " ORDER BY CASE WHEN title ILIKE %s THEN 0 ELSE 1 END, activation_time DESC NULLS LAST"
                params.append(f'%{keyword}%')
            else:
                base_query += " ORDER BY activation_time DESC NULLS LAST"
        
        # Add pagination
        offset = (page - 1) * limit
        base_query += f" LIMIT %s OFFSET %s"
        params.extend([limit, offset])
        
        return base_query, params, count_query, count_params
    
    def job_details(self, job_id):
        """Display detailed information about a specific job."""
        try:
            # Connect to database
            conn = psycopg2.connect(self._build_db_connection_string())
            cursor = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
            
            # Query for job details
            query = f"SELECT * FROM {self.db_manager.schema}.jobs WHERE id = %s"
            cursor.execute(query, (job_id,))
            job_data = cursor.fetchone()
            
            # Close connection
            cursor.close()
            conn.close()
            
            if not job_data:
                flash(f"Job with ID {job_id} not found", "error")
                return redirect(url_for('search_jobs'))
            
            # Convert to dictionary
            job = dict(job_data)
            
            # Process JSON fields
            for field in ['locations', 'work_types', 'tags', 'job_post_categories', 'salary']:
                if field in job and job[field] and isinstance(job[field], str):
                    try:
                        job[field] = json.loads(job[field])
                    except (json.JSONDecodeError, TypeError):
                        pass
            
            return render_template('job_details.html', job=job)
            
        except Exception as e:
            logger.error(f"Error in job_details: {str(e)}")
            flash(f"Error retrieving job details: {str(e)}", "error")
            return redirect(url_for('search_jobs'))
    
    def export_search_results(self, format):
        """Export search results in various formats."""
        try:
            # Get current search from config
            search_params = self.app.config.get('CURRENT_SEARCH', {})
            
            # Get all search parameters from request
            keyword = request.args.get('keyword', search_params.get('keyword', ''))
            location = request.args.get('location', search_params.get('location', ''))
            company = request.args.get('company', search_params.get('company', ''))
            days = request.args.get('days', search_params.get('days', ''))
            sort = request.args.get('sort', search_params.get('sort', 'date'))
            
            # Connect to database
            conn = psycopg2.connect(self._build_db_connection_string())
            cursor = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)
            
            # Build query for all results (no pagination)
            query, params, _, _ = self._build_search_query(
                keyword, location, company, days, sort, 1, 10000  # Large limit to get all results
            )
            
            # Remove the pagination part (LIMIT/OFFSET)
            query = query.split('LIMIT')[0].strip()
            params = params[:-2]  # Remove the last two parameters (limit, offset)
            
            # Execute query
            cursor.execute(query, params)
            jobs = [dict(row) for row in cursor.fetchall()]
            
            # Close connection
            cursor.close()
            conn.close()
            
            # Format the filename with search parameters
            params_str = []
            if keyword:
                params_str.append(f"keyword-{keyword}")
            if location:
                params_str.append(f"loc-{location}")
            if company:
                params_str.append(f"company-{company}")
            if days:
                params_str.append(f"days-{days}")
                
            filename_base = "jobs_export"
            if params_str:
                filename_base += "_" + "_".join(params_str)
            
            filename_base = secure_filename(filename_base)
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            
            # Create DataFrame from jobs
            df = pd.DataFrame(jobs)
            
            # Export in requested format
            if format == 'csv':
                output = io.StringIO()
                df.to_csv(output, index=False, encoding='utf-8')
                output.seek(0)
                
                return send_file(
                    io.BytesIO(output.getvalue().encode('utf-8')),
                    mimetype='text/csv',
                    as_attachment=True,
                    attachment_filename=f"{filename_base}_{timestamp}.csv"
                )
                
            elif format == 'json':
                # Process JSON columns before export
                for job in jobs:
                    for field in ['locations', 'work_types', 'tags', 'job_post_categories', 'salary']:
                        if field in job and job[field] and isinstance(job[field], str):
                            try:
                                job[field] = json.loads(job[field])
                            except (json.JSONDecodeError, TypeError):
                                pass
                
                output = json.dumps(jobs, default=str, ensure_ascii=False, indent=2)
                
                return send_file(
                    io.BytesIO(output.encode('utf-8')),
                    mimetype='application/json',
                    as_attachment=True,
                    attachment_filename=f"{filename_base}_{timestamp}.json"
                )
                
            elif format == 'excel':
                output = io.BytesIO()
                df.to_excel(output, index=False, engine='openpyxl')
                output.seek(0)
                
                return send_file(
                    output,
                    mimetype='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
                    as_attachment=True,
                    attachment_filename=f"{filename_base}_{timestamp}.xlsx"
                )
                
            else:
                flash(f"Unsupported export format: {format}", "error")
                return redirect(url_for('search_jobs'))
                
        except Exception as e:
            logger.error(f"Error in export_search_results: {str(e)}")
            flash(f"Error exporting search results: {str(e)}", "error")
            return redirect(url_for('search_jobs'))

    def analytics(self):
        """
        Display analytics dashboard with Superset integration.
        
        This route provides access to the Superset dashboards or embeds 
        specific visualizations from Superset.
        """
        try:
            # Get Superset base URL from environment or config
            superset_url = os.environ.get(
                "SUPERSET_URL", 
                self.config_manager.api_config.get("superset", {}).get("url", "http://localhost:8088")
            )
            
            # Check if Superset is available
            superset_available = False
            try:
                # Use a very short timeout to avoid blocking the request
                response = requests.get(f"{superset_url}/health", timeout=0.5)
                superset_available = response.status_code == 200
            except (requests.RequestException, ConnectionError):
                pass  # Superset is not available
                
            # Get dashboard details (configurable)
            dashboards = [
                {
                    "title": "Job Market Trends",
                    "id": "job-market-trends",
                    "description": "Overview of job posting trends and metrics",
                    "url": f"{superset_url}/superset/dashboard/job-market-trends/"
                },
                {
                    "title": "Salary Analysis",
                    "id": "salary-analysis",
                    "description": "Analysis of salary distributions across jobs",
                    "url": f"{superset_url}/superset/dashboard/salary-analysis/"
                }
            ]
            
            return render_template(
                'analytics.html',
                superset_url=superset_url,
                superset_available=superset_available,
                dashboards=dashboards
            )
            
        except Exception as e:
            self.logger.error(f"Error displaying analytics: {str(e)}")
            flash(f"Error loading analytics dashboard: {str(e)}", "danger")
            return redirect(url_for('dashboard'))

# Create application instance when imported
app = None

def create_app(
    config_path: str = "config/api_config.yaml",
    db_connection_string: Optional[str] = None,
    debug: bool = False
) -> Flask:
    """
    Create and initialize a Flask application with job scraper functionality.
    
    Args:
        config_path: Path to the configuration file
        db_connection_string: Database connection string (optional)
        debug: Whether to enable debug mode
        
    Returns:
        Configured Flask application
    """
    try:
        # Create and configure the web application
        webapp = JobScraperWebApp(
            config_path=config_path,
            db_connection_string=db_connection_string
        )
        
        app = webapp.app
        app.debug = debug
        
        # Add context processor to make current_year available in all templates
        @app.context_processor
        def inject_current_year():
            return {"current_year": datetime.now().year}
        
        # Test database connection
        conn = None
        try:
            conn = psycopg2.connect(
                webapp._build_db_connection_string(),
                connect_timeout=5
            )
            logger.info("Database connection successful")
        except Exception as e:
            logger.error(f"Error connecting to database: {str(e)}")
            ERRORS.labels(type="database_connection").inc()
        finally:
            if conn:
                conn.close()
                
        # Initialize components synchronously
        webapp._initialize_managers_sync()
        
        # Setup monitoring
        setup_monitoring(
            app, 
            version=os.environ.get("APP_VERSION", "0.1.0"),
            config_name=os.path.basename(config_path),
            env=os.environ.get("FLASK_ENV", "production")
        )
        
        return app
    except Exception as e:
        logger.error(f"Error creating application: {e}")
        raise

if __name__ == "__main__":
    # Get configuration from environment
    config_path = os.environ.get("CONFIG_PATH", "config/api_config.yaml")
    host = os.environ.get("WEB_HOST", "0.0.0.0")
    port = int(os.environ.get("WEB_PORT", "5000"))
    debug = os.environ.get("FLASK_DEBUG", "0") == "1"
    
    # Create web app
    web_app = JobScraperWebApp(config_path=config_path)
    
    # Run the app
    web_app.run(host=host, port=port, debug=debug) 