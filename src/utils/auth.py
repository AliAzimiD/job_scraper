from functools import wraps
from typing import Callable, Optional

from flask import Flask, request, jsonify, Response, current_app
from werkzeug.security import check_password_hash
import base64

from ..log_setup import get_logger

# Get logger
logger = get_logger("auth")

def setup_auth(app: Flask) -> None:
    """
    Setup authentication for the application.
    
    Args:
        app: Flask application
    """
    @app.before_request
    def check_auth():
        """
        Check authentication for API routes if enabled.
        """
        # Only check auth for API routes
        if request.path.startswith('/api/'):
            # Skip auth for health check endpoint
            if request.path == '/api/health':
                return None
                
            # Check if auth is enabled
            if not current_app.config.get('API_AUTH_ENABLED', False):
                return None
                
            auth = get_auth_from_request(request)
            if not auth or not check_credentials(auth[0], auth[1]):
                logger.warning(f"Authentication failed for {request.path}")
                return jsonify({'error': 'Unauthorized access'}), 401
    
    logger.info("Authentication setup completed")

def get_auth_from_request(request) -> Optional[tuple]:
    """
    Extract authentication credentials from the request.
    
    Args:
        request: Flask request object
        
    Returns:
        Tuple of (username, password) or None if not found
    """
    auth_header = request.headers.get('Authorization')
    if not auth_header:
        return None
        
    try:
        auth_type, auth_string = auth_header.split(' ', 1)
        if auth_type.lower() != 'basic':
            return None
            
        auth_decoded = base64.b64decode(auth_string).decode('utf-8')
        username, password = auth_decoded.split(':', 1)
        return (username, password)
    except Exception as e:
        logger.error(f"Error parsing auth header: {e}")
        return None

def check_credentials(username: str, password: str) -> bool:
    """
    Check if credentials are valid.
    
    Args:
        username: Username to check
        password: Password to check
        
    Returns:
        True if credentials are valid, False otherwise
    """
    expected_username = current_app.config.get('API_AUTH_USERNAME')
    expected_password = current_app.config.get('API_AUTH_PASSWORD')
    
    return username == expected_username and password == expected_password

def api_auth_required(f: Callable) -> Callable:
    """
    Decorator for routes that require API authentication.
    
    Args:
        f: Function to decorate
        
    Returns:
        Decorated function
    """
    @wraps(f)
    def decorated(*args, **kwargs):
        # Skip auth check if disabled in config
        if not current_app.config.get('API_AUTH_ENABLED', False):
            return f(*args, **kwargs)
            
        auth = get_auth_from_request(request)
        if not auth or not check_credentials(auth[0], auth[1]):
            logger.warning(f"API authentication failed for {request.path}")
            return jsonify({'error': 'Unauthorized access'}), 401
            
        return f(*args, **kwargs)
    return decorated 