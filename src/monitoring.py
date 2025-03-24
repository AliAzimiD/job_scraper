"""
Monitoring module for job scraper application

This module provides Prometheus metrics integration for the Flask web application
"""

import time
import psutil
from prometheus_client import Counter, Gauge, Histogram, Info, generate_latest, CONTENT_TYPE_LATEST
from flask import request, Response


# Job scraping metrics
TOTAL_JOBS = Gauge('job_scraper_total_jobs', 'Total number of jobs in the database')
NEW_JOBS = Counter('job_scraper_new_jobs_total', 'Number of new jobs scraped')
ERRORS = Counter('job_scraper_errors_total', 'Number of scraper errors', ['type'])
RETRIES = Counter('job_scraper_retries_total', 'Number of scraper retries')

# API metrics
API_REQUESTS = Counter('job_scraper_api_requests_total', 'Number of API requests', ['method', 'endpoint', 'status'])
API_REQUEST_DURATION = Histogram('job_scraper_api_request_duration_seconds', 'API request duration in seconds',
                                ['method', 'endpoint'])

# Scraping performance metrics
SCRAPE_DURATION = Histogram('job_scraper_scrape_duration_seconds', 'Time spent scraping jobs',
                           ['source'], buckets=[1, 5, 10, 30, 60, 120, 300, 600])
DB_OPERATION_DURATION = Histogram('job_scraper_db_operation_duration_seconds', 'Time spent on database operations',
                                 ['operation'], buckets=[0.01, 0.05, 0.1, 0.5, 1, 5])

# Resource usage metrics
CPU_USAGE = Gauge('job_scraper_cpu_usage', 'CPU usage percentage')
MEMORY_USAGE = Gauge('job_scraper_memory_usage_bytes', 'Memory usage in bytes')

# Application info
APP_INFO = Info('job_scraper_app_info', 'Job scraper application information')


def init_app_info(version, config_name, env):
    """Initialize application info metrics"""
    APP_INFO.info({
        'version': version,
        'config': config_name,
        'environment': env
    })


def update_resource_metrics():
    """Update resource usage metrics"""
    process = psutil.Process()
    CPU_USAGE.set(process.cpu_percent() / 100.0)  # Convert to a value between 0-1 for Prometheus
    MEMORY_USAGE.set(process.memory_info().rss)


def before_request():
    """Set up tracking for request duration"""
    request.start_time = time.time()


def after_request(response):
    """Record request duration and count"""
    request_latency = time.time() - request.start_time
    API_REQUEST_DURATION.labels(
        method=request.method,
        endpoint=request.endpoint or 'unknown'
    ).observe(request_latency)
    
    API_REQUESTS.labels(
        method=request.method,
        endpoint=request.endpoint or 'unknown',
        status=response.status_code
    ).inc()
    
    return response


def metrics_endpoint():
    """Endpoint to expose Prometheus metrics"""
    update_resource_metrics()
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


def setup_monitoring(app, version='0.1.0', config_name='default', env='production'):
    """Set up monitoring for the Flask application"""
    init_app_info(version, config_name, env)
    
    # Register before/after request handlers
    app.before_request(before_request)
    app.after_request(after_request)
    
    # Add metrics endpoint
    app.add_url_rule('/metrics', 'metrics', metrics_endpoint)
    
    return app 