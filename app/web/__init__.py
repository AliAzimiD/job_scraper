"""
Web package for the Job Scraper application.

This package contains all the web interface components,
including routes, views, forms, and filters.
"""

from flask import Flask


def init_app(app: Flask) -> None:
    """
    Register blueprints and initialize web module components.
    
    Args:
        app: Flask application instance
    """
    # Register template filters
    from app.web.filters import register_filters
    register_filters(app)
    
    # Register blueprints
    from app.web.views.main import main_bp
    from app.web.views.api import api_bp
    from app.web.views.scraper import scraper_bp
    from app.web.views.import_export import import_export_bp
    
    app.register_blueprint(main_bp)
    app.register_blueprint(api_bp, url_prefix='/api')
    app.register_blueprint(scraper_bp, url_prefix='/scraper')
    app.register_blueprint(import_export_bp, url_prefix='/import-export')
