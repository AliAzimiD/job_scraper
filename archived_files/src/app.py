import os
from pathlib import Path
from typing import Optional, Dict, Any

from flask import Flask, render_template
from flask_bootstrap import Bootstrap

from .log_setup import get_logger
from .config_manager import ConfigManager
from .services.db_service import get_db_service, DatabaseService
from .services.job_repository import JobRepository
from .services.scraper_service import ScraperService
from .utils.auth import setup_auth
from .utils.error_handlers import register_error_handlers
from .utils.logging import setup_logger

# Configure logger
logger = setup_logger("app")

def create_app(
    config_path: str = "config/api_config.yaml",
    db_connection_string: Optional[str] = None,
    testing: bool = False
) -> Flask:
    """
    Create and configure the Flask application using the Application Factory pattern.
    
    Args:
        config_path: Path to configuration file
        db_connection_string: Database connection string (optional)
        testing: Whether the app is in testing mode
        
    Returns:
        Configured Flask application
    """
    # Create and configure the app
    app = Flask(__name__)
    app.config.from_mapping(
        SECRET_KEY=os.environ.get("FLASK_SECRET_KEY", "dev-key"),
        UPLOAD_FOLDER=os.environ.get("UPLOAD_FOLDER", "uploads"),
        DATA_DIR=os.environ.get("DATA_DIR", "job_data"),
        BACKUP_DIR=os.environ.get("BACKUP_DIR", "backups"),
        MAX_CONTENT_LENGTH=100 * 1024 * 1024,  # 100MB upload limit
        TESTING=testing,
        API_AUTH_ENABLED=os.environ.get("API_AUTH_ENABLED", "0") == "1",
        API_AUTH_USERNAME=os.environ.get("API_AUTH_USERNAME", "admin"),
        API_AUTH_PASSWORD=os.environ.get("API_AUTH_PASSWORD", "password"),
        DB_HOST=os.environ.get('DB_HOST', 'localhost'),
        DB_PORT=os.environ.get('DB_PORT', '5432'),
        DB_NAME=os.environ.get('DB_NAME', 'jobsdb'),
        DB_USER=os.environ.get('DB_USER', 'postgres'),
        DB_PASSWORD=os.environ.get('DB_PASSWORD', ''),
        API_USERNAME=os.environ.get('API_USERNAME', 'admin'),
        API_PASSWORD=os.environ.get('API_PASSWORD', 'password')
    )
    
    # Ensure directories exist
    for dir_name in ['UPLOAD_FOLDER', 'DATA_DIR', 'BACKUP_DIR']:
        Path(app.config[dir_name]).mkdir(exist_ok=True, parents=True)
    
    # Initialize extensions
    bootstrap = Bootstrap(app)
    
    # Initialize services
    init_services(app, config_path, db_connection_string)
    
    # Setup authentication if enabled
    if app.config['API_AUTH_ENABLED']:
        setup_auth(app)
    
    # Register blueprints
    register_blueprints(app)
    
    # Register error handlers
    register_error_handlers(app)
    
    # Add app context logging
    @app.before_request
    def before_request_logging():
        """Log before processing each request."""
        from flask import request
        logger.debug(f"Request: {request.method} {request.path}")
    
    @app.after_request
    def after_request_logging(response):
        """Log after processing each request."""
        from flask import request
        logger.debug(f"Response: {request.method} {request.path} {response.status_code}")
        return response
    
    logger.info("Application initialized successfully")
    return app

def init_services(
    app: Flask,
    config_path: str,
    db_connection_string: Optional[str] = None
) -> None:
    """
    Initialize application services and attach them to the app.
    
    Args:
        app: Flask application
        config_path: Path to configuration file
        db_connection_string: Database connection string (optional)
    """
    # Initialize configuration manager
    app.config_manager = ConfigManager(config_path)
    
    # Get database connection parameters from environment if not provided
    if not db_connection_string:
        db_config = app.config_manager.database_config
        db_connection_string = db_config.get("connection_string")
    
    # Initialize database service
    db_service = get_db_service()
    
    # Initialize job repository
    app.job_repository = JobRepository(db_service=db_service)
    
    # Initialize scraper service
    max_concurrent_requests = int(os.environ.get("MAX_CONCURRENT_REQUESTS", "10"))
    rate_limit_ms = int(os.environ.get("RATE_LIMIT_REQUEST_INTERVAL_MS", "200"))
    
    app.scraper_service = ScraperService(
        config_path=config_path,
        job_repository=app.job_repository,
        max_concurrent_requests=max_concurrent_requests,
        rate_limit_interval_ms=rate_limit_ms
    )
    
    logger.info("Application services initialized")

def register_blueprints(app: Flask) -> None:
    """
    Register Flask blueprints.
    
    Args:
        app: Flask application
    """
    # Import blueprints at function level to avoid circular imports
    from .blueprints.dashboard.routes import dashboard_bp
    from .blueprints.scraper.routes import scraper_bp
    from .blueprints.data_management.routes import data_bp
    from .blueprints.api.routes import api_bp
    
    # Register blueprints
    app.register_blueprint(dashboard_bp)
    app.register_blueprint(scraper_bp, url_prefix='/scraper')
    app.register_blueprint(data_bp, url_prefix='/data')
    app.register_blueprint(api_bp, url_prefix='/api')
    
    logger.info("Application blueprints registered")

def register_error_handlers(app: Flask) -> None:
    """
    Register custom error handlers.
    
    Args:
        app: Flask application
    """
    @app.errorhandler(404)
    def page_not_found(e):
        """Handle 404 errors."""
        return render_template('errors/404.html'), 404
    
    @app.errorhandler(500)
    def server_error(e):
        """Handle 500 errors."""
        logger.error(f"Server error: {e}")
        return render_template('errors/500.html'), 500
    
    logger.info("Application error handlers registered")

# Create the application when module is imported
app = None

def get_app():
    """Get or create the Flask app instance."""
    global app
    if app is None:
        config_path = os.environ.get("CONFIG_PATH", "config/api_config.yaml")
        debug = os.environ.get("FLASK_DEBUG", "0") == "1"
        app = create_app(config_path=config_path)
        app.debug = debug
    return app 