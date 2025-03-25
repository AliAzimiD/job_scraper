"""
Prometheus metrics for the Job Scraper application.
"""

import time
import logging
from flask import Blueprint, Response, request

from prometheus_client import Counter, Gauge, Histogram, Info, generate_latest, CONTENT_TYPE_LATEST

# Set up logger
logger = logging.getLogger(__name__)

# Create metrics
REQUEST_COUNT = Counter(
    'request_count', 'App Request Count',
    ['app_name', 'method', 'endpoint', 'http_status']
)
REQUEST_LATENCY = Histogram(
    'request_latency_seconds', 'Request latency',
    ['app_name', 'endpoint']
)
REQUEST_IN_PROGRESS = Gauge(
    'requests_in_progress', 'Requests in progress',
    ['app_name', 'endpoint']
)
JOBS_SCRAPED = Counter(
    'jobs_scraped_total', 'Total number of jobs scraped',
    ['source', 'status']
)
JOBS_ADDED = Counter(
    'jobs_added_total', 'Total number of new jobs added to database',
    ['source']
)
SCRAPER_RUNTIME = Histogram(
    'scraper_runtime_seconds', 'Scraper runtime in seconds',
    ['source', 'status']
)
DB_OPERATIONS = Counter(
    'db_operations_total', 'Database operations',
    ['operation', 'status']
)
DB_QUERY_LATENCY = Histogram(
    'db_query_latency_seconds', 'Database query latency',
    ['operation']
)
APP_INFO = Info('app_info', 'Application information')

# Create metrics blueprint
metrics_bp = Blueprint('metrics', __name__)

@metrics_bp.route('/metrics')
def metrics():
    """Metrics endpoint for Prometheus scraper."""
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)

def setup_monitoring(app):
    """Set up monitoring for the application.
    
    Args:
        app: Flask application instance
    """
    app.register_blueprint(metrics_bp)
    
    # Set up basic app info
    APP_INFO.info({
        'version': app.config.get('VERSION', 'unknown'),
        'environment': app.config.get('ENVIRONMENT', 'development')
    })
    
    # Set up before_request and after_request handlers for metrics
    @app.before_request
    def before_request():
        request.start_time = time.time()
        REQUEST_IN_PROGRESS.labels(
            app_name=app.name,
            endpoint=request.endpoint or 'unknown'
        ).inc()

    @app.after_request
    def after_request(response):
        request_latency = time.time() - request.start_time
        REQUEST_LATENCY.labels(
            app_name=app.name,
            endpoint=request.endpoint or 'unknown'
        ).observe(request_latency)
        
        REQUEST_COUNT.labels(
            app_name=app.name,
            method=request.method,
            endpoint=request.endpoint or 'unknown',
            http_status=response.status_code
        ).inc()
        
        REQUEST_IN_PROGRESS.labels(
            app_name=app.name,
            endpoint=request.endpoint or 'unknown'
        ).dec()
        
        return response
    
    logger.info("Prometheus monitoring set up")
    
    return app 