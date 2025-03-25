"""
Job Scraper Application Package

This package contains all the components for the job scraper application.
"""

import os
import yaml
from flask import Flask
from flask_cors import CORS
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

def create_app(config_path=None):
    """
    Create and configure the Flask application

    Args:
        config_path: Path to the configuration file (optional)

    Returns:
        Flask: The configured Flask application
    """
    # Create Flask app
    app = Flask(__name__, 
                template_folder='templates',
                static_folder='../static')
    
    # Set up CORS
    CORS(app)
    
    # Configure app from config file or environment
    if config_path and os.path.exists(config_path):
        # Check file extension to determine how to load it
        if config_path.endswith('.yaml') or config_path.endswith('.yml'):
            with open(config_path, 'r') as config_file:
                config_data = yaml.safe_load(config_file)
                if 'app' in config_data and isinstance(config_data['app'], dict):
                    app.config.update(config_data['app'])
                else:
                    app.config.update(config_data)
        else:
            app.config.from_pyfile(config_path)
    else:
        app.config.from_mapping(
            SECRET_KEY=os.environ.get('FLASK_SECRET_KEY', 'dev-key-for-testing'),
            UPLOAD_FOLDER=os.environ.get('UPLOAD_FOLDER', 'uploads'),
            MAX_CONTENT_LENGTH=100 * 1024 * 1024,  # 100 MB
        )
    
    # Initialize database
    from app.db import init_db
    init_db(app)
    
    # Register blueprints
    from app.web import init_app
    init_app(app)
    
    # Set up monitoring
    from app.monitoring import setup_monitoring
    setup_monitoring(app)
    
    # Register error handlers
    register_error_handlers(app)
    
    return app

def register_error_handlers(app):
    """Register error handlers for the application."""
    
    from flask import render_template
    from app.core.exceptions import JobScraperError, ResourceNotFoundError
    
    @app.errorhandler(404)
    def page_not_found(e):
        return render_template('errors/404.html'), 404
    
    @app.errorhandler(500)
    def server_error(e):
        return render_template('errors/500.html', error=str(e)), 500
    
    @app.errorhandler(JobScraperError)
    def handle_job_scraper_error(e):
        return render_template('errors/500.html', error=e.message), 500
    
    @app.errorhandler(ResourceNotFoundError)
    def handle_resource_not_found(e):
        return render_template('errors/404.html', error=e.message), 404
