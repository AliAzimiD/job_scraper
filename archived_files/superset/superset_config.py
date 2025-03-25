"""
Superset configuration for job scraper integration.
This file configures Apache Superset to work with our job scraper database.
"""
import os
from datetime import timedelta
from cachelib.file import FileSystemCache

# Database connection string
SQLALCHEMY_DATABASE_URI = os.environ.get(
    "SUPERSET_DB_URI", 
    "postgresql://jobuser:devpassword@postgres:5432/jobsdb"
)

# Flask App Builder configuration
# Your App secret key will be used for securely signing the session cookie
# and encrypting sensitive information on the database
SECRET_KEY = os.environ.get("SUPERSET_SECRET_KEY", "job-scraper-superset-secret-key")

# The SQLAlchemy connection string to the metadata database
SQLALCHEMY_EXAMPLES_URI = SQLALCHEMY_DATABASE_URI

# Flask-WTF flag for CSRF
WTF_CSRF_ENABLED = True
# Add endpoints that need to be exempt from CSRF protection
WTF_CSRF_EXEMPT_LIST = []
# A CSRF token that expires in 1 year
WTF_CSRF_TIME_LIMIT = 60 * 60 * 24 * 365

# Set this API key to enable Mapbox visualizations
MAPBOX_API_KEY = os.environ.get("MAPBOX_API_KEY", "")

# Cache configuration
CACHE_CONFIG = {
    'CACHE_TYPE': 'FileSystemCache',
    'CACHE_DIR': '/app/superset_home/cache',
    'CACHE_DEFAULT_TIMEOUT': 60 * 60 * 24,  # 1 day default cache timeout
}

# Allowed hosts (if behind reverse proxy)
SUPERSET_WEBSERVER_DOMAINS = os.environ.get("ALLOWED_HOSTS", "*")

# Feature flags
FEATURE_FLAGS = {
    "ALERT_REPORTS": True,
    "DASHBOARD_NATIVE_FILTERS": True,
    "DASHBOARD_CROSS_FILTERS": True,
    "EMBEDDED_SUPERSET": True,
    "ENABLE_TEMPLATE_PROCESSING": True,
}

# Enable CORS
ENABLE_CORS = True
CORS_OPTIONS = {
    'supports_credentials': True,
    'allow_headers': ['*'],
    'resources': ['*'],
    'origins': ['*']
}

# Configure Celery
class CeleryConfig:
    BROKER_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")
    CELERY_IMPORTS = ("superset.sql_lab", )
    CELERY_RESULT_BACKEND = os.environ.get("REDIS_URL", "redis://redis:6379/0")
    CELERY_ANNOTATIONS = {"tasks.add": {"rate_limit": "10/s"}}
    CONCURRENCY = 4

CELERY_CONFIG = CeleryConfig

# Job scraper specific dashboard configuration
DASHBOARD_TIME_RANGE = "Last 90 days"

# Default data visualizations
DEFAULT_VISUALIZATION_NAME = "Job Scraper Dashboard"

# Custom CSS for branding
CUSTOM_CSS = """
.navbar {
    background-color: #4a7c94 !important;
}
.navbar-brand img {
    width: 120px;
}
""" 