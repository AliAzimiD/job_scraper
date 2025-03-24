"""
log_setup.py
Centralized logging configuration to be used by all modules in the Job Scraper project.
"""
import logging
import sys
from pathlib import Path
from datetime import datetime
import os
import json
from logging.handlers import RotatingFileHandler, TimedRotatingFileHandler
from typing import Optional, Dict, Any, Union

# Default log format
DEFAULT_LOG_FORMAT = '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
DEFAULT_LOG_LEVEL = 'INFO'

# JSON formatter for structured logging
class JsonFormatter(logging.Formatter):
    """
    Formatter that outputs JSON strings after parsing the log record.
    """
    def __init__(self, fmt_dict: Optional[Dict[str, Any]] = None):
        """
        Initialize with optional format dictionary.
        """
        self.fmt_dict = fmt_dict if fmt_dict else {}
        super().__init__()
        
    def format(self, record: logging.LogRecord) -> str:
        """
        Format the record as JSON.
        """
        record_dict = {
            'timestamp': self.formatTime(record),
            'level': record.levelname,
            'name': record.name,
            'module': record.module,
            'function': record.funcName,
            'line': record.lineno,
            'message': record.getMessage(),
        }
        
        # Add exception info if available
        if record.exc_info:
            record_dict['exception'] = {
                'type': record.exc_info[0].__name__,
                'message': str(record.exc_info[1]),
                'traceback': self.formatException(record.exc_info)
            }
            
        # Add custom fields from the format dictionary
        for key, value in self.fmt_dict.items():
            if key in record.__dict__:
                record_dict[key] = record.__dict__[key]
                
        # Add extra attributes from the log record
        if hasattr(record, 'data') and isinstance(record.data, dict):
            record_dict.update(record.data)
            
        return json.dumps(record_dict)

def get_logger(name: str, 
               level: Optional[str] = None, 
               log_to_file: bool = True,
               log_to_console: bool = True,
               log_format: str = DEFAULT_LOG_FORMAT,
               json_format: bool = False,
               log_dir: Optional[str] = None) -> logging.Logger:
    """
    Get a configured logger instance.
    
    Args:
        name: Name of the logger
        level: Log level (default from environment or INFO)
        log_to_file: Whether to log to file
        log_to_console: Whether to log to console
        log_format: Log format string
        json_format: Whether to use JSON formatting
        log_dir: Directory for log files
        
    Returns:
        Configured logger instance
    """
    # Get log level from environment or use default
    log_level = level or os.environ.get('LOG_LEVEL', DEFAULT_LOG_LEVEL)
    numeric_level = getattr(logging, log_level.upper(), None)
    
    if not isinstance(numeric_level, int):
        print(f"Invalid log level: {log_level}", file=sys.stderr)
        numeric_level = logging.INFO
        
    # Get or create logger
    logger = logging.getLogger(name)
    
    # Return existing logger if already configured
    if logger.handlers:
        return logger
        
    logger.setLevel(numeric_level)
    logger.propagate = False  # Don't pass logs to ancestor loggers
    
    # Create formatter
    if json_format:
        formatter = JsonFormatter()
    else:
        formatter = logging.Formatter(log_format)
    
    # Add console handler if requested
    if log_to_console:
        console_handler = logging.StreamHandler(sys.stdout)
        console_handler.setFormatter(formatter)
        logger.addHandler(console_handler)
    
    # Add file handler if requested
    if log_to_file:
        # Get log directory
        if not log_dir:
            log_dir = os.environ.get('LOG_DIR', 'logs')
            
        # Create log directory if it doesn't exist
        log_path = Path(log_dir)
        log_path.mkdir(exist_ok=True, parents=True)
        
        # Determine log filename
        log_file = log_path / f"{name}.log"
        
        # Create rotating file handler
        max_bytes = int(os.environ.get('LOG_MAX_BYTES', 10 * 1024 * 1024))  # 10 MB
        backup_count = int(os.environ.get('LOG_BACKUP_COUNT', 5))
        
        file_handler = RotatingFileHandler(
            log_file,
            maxBytes=max_bytes,
            backupCount=backup_count
        )
        file_handler.setFormatter(formatter)
        logger.addHandler(file_handler)
    
    return logger

def configure_request_logger(app, log_dir: Optional[str] = None) -> None:
    """
    Configure request logging for a Flask application.
    
    Args:
        app: Flask application instance
        log_dir: Directory for log files
    """
    if not log_dir:
        log_dir = os.environ.get('LOG_DIR', 'logs')
        
    # Create request logger
    request_logger = get_logger(
        'requests',
        log_to_file=True,
        log_to_console=False,
        json_format=True,
        log_dir=log_dir
    )
    
    # Create before request handler
    @app.before_request
    def before_request():
        """
        Log request details before processing.
        """
        import flask
        request = flask.request
        
        # Skip logging for static files if desired
        if request.path.startswith('/static'):
            return
            
        # Log request information
        request_logger.info(
            f"Request: {request.method} {request.path}",
            extra={
                'data': {
                    'request': {
                        'method': request.method,
                        'path': request.path,
                        'query': request.query_string.decode('utf-8', errors='replace'),
                        'remote_addr': request.remote_addr,
                        'user_agent': request.user_agent.string,
                        'content_length': request.content_length,
                        'content_type': request.content_type,
                    }
                }
            }
        )
        
    # Create after request handler
    @app.after_request
    def after_request(response):
        """
        Log response details after processing.
        
        Args:
            response: Flask response
            
        Returns:
            Unchanged response
        """
        import flask
        import time
        request = flask.request
        
        # Skip logging for static files if desired
        if request.path.startswith('/static'):
            return response
            
        # Calculate request duration
        start_time = getattr(flask.g, 'start_time', time.time())
        duration_ms = int((time.time() - start_time) * 1000)
        
        # Log response information
        request_logger.info(
            f"Response: {request.method} {request.path} - {response.status_code}",
            extra={
                'data': {
                    'request': {
                        'method': request.method,
                        'path': request.path,
                    },
                    'response': {
                        'status_code': response.status_code,
                        'content_length': response.content_length,
                        'duration_ms': duration_ms,
                    }
                }
            }
        )
        
        return response
        
    # Configure logging for errors
    @app.errorhandler(Exception)
    def log_exception(error):
        """
        Log unhandled exceptions.
        
        Args:
            error: The unhandled exception
            
        Raises:
            The original exception for Flask to handle
        """
        app.logger.exception(f"Unhandled exception: {error}")
        raise error
