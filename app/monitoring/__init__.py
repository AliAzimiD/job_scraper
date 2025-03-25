"""
Monitoring package for the Job Scraper application.

This package provides monitoring functionality including:
- Prometheus metrics collection and exposure
- Health check endpoints for application status
- Resource usage monitoring

Import the setup_monitoring function to initialize all monitoring components
with a Flask application instance.
"""

from app.monitoring.metrics import setup_metrics
from app.monitoring.health import create_health_endpoints


def setup_monitoring(app):
    """Initialize all monitoring for the application.
    
    This function sets up health checks and metrics collection for the 
    provided Flask application instance.
    
    Args:
        app: Flask application instance
    """
    # Setup Prometheus metrics
    setup_metrics(app)
    
    # Setup health check endpoints
    create_health_endpoints(app)
    
    app.logger.info("Monitoring setup complete: health checks and metrics enabled")


__all__ = ['setup_monitoring']
