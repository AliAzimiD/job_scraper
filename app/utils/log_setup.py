"""
Logging Setup Module for Job Scraper Application

This module provides a centralized configuration for application logging,
supporting both structured logging to files and console output.
"""

import os
import logging
import logging.config
import yaml
import json
from typing import Any, Dict, Optional
from datetime import datetime
from pathlib import Path

# Default logging configuration
DEFAULT_LOG_CONFIG = {
    "version": 1,
    "disable_existing_loggers": False,
    "formatters": {
        "standard": {
            "format": "%(asctime)s - %(name)s - %(levelname)s - %(message)s"
        },
        "json": {
            "format": "%(message)s",
            "class": "pythonjsonlogger.jsonlogger.JsonFormatter",
            "datefmt": "%Y-%m-%dT%H:%M:%S%z"
        }
    },
    "handlers": {
        "console": {
            "class": "logging.StreamHandler",
            "level": "INFO",
            "formatter": "standard",
            "stream": "ext://sys.stdout"
        },
        "file": {
            "class": "logging.handlers.RotatingFileHandler",
            "level": "INFO",
            "formatter": "standard",
            "filename": "logs/app.log",
            "maxBytes": 10485760,  # 10MB
            "backupCount": 10,
            "encoding": "utf8"
        },
        "json_file": {
            "class": "logging.handlers.RotatingFileHandler",
            "level": "INFO",
            "formatter": "json",
            "filename": "logs/app.json",
            "maxBytes": 10485760,  # 10MB
            "backupCount": 10,
            "encoding": "utf8"
        }
    },
    "loggers": {
        "": {  # root logger
            "handlers": ["console", "file"],
            "level": "INFO",
            "propagate": True
        },
        "job_scraper": {
            "handlers": ["console", "file", "json_file"],
            "level": "INFO",
            "propagate": False
        },
        "api": {
            "handlers": ["console", "file", "json_file"],
            "level": "INFO",
            "propagate": False
        },
        "db": {
            "handlers": ["console", "file"],
            "level": "INFO",
            "propagate": False
        },
        "werkzeug": {
            "handlers": ["console"],
            "level": "WARNING",
            "propagate": False
        },
        "sqlalchemy.engine": {
            "handlers": ["file"],
            "level": "WARNING",
            "propagate": False
        }
    }
}

class StructuredLogAdapter(logging.LoggerAdapter):
    """
    Logger adapter that adds structured context to all log records.
    """
    
    def __init__(self, logger, extra=None):
        """Initialize the adapter with default extra fields."""
        super().__init__(logger, extra or {})
    
    def process(self, msg, kwargs):
        """Process the logging message and keyword arguments."""
        extra = self.extra.copy()
        
        # Add timestamp if not present
        if "timestamp" not in extra:
            extra["timestamp"] = datetime.now().isoformat()
        
        # Add trace information if available
        if hasattr(logging, "current_trace_id") and hasattr(logging, "current_span_id"):
            extra["trace_id"] = getattr(logging, "current_trace_id", None)
            extra["span_id"] = getattr(logging, "current_span_id", None)
        
        # Add any additional extra fields from kwargs
        if "extra" in kwargs:
            extra.update(kwargs["extra"])
            # Don't modify the original kwargs to avoid unexpected behavior
            kwargs_copy = kwargs.copy()
            kwargs_copy["extra"] = extra
            return msg, kwargs_copy
        
        # Add our extras to kwargs
        kwargs["extra"] = extra
        return msg, kwargs
    
    def addContext(self, **kwargs):
        """Add additional context to the logger."""
        self.extra.update(kwargs)


def setup_logging(config_path: Optional[str] = None, default_level: str = "INFO") -> None:
    """
    Set up logging configuration from a file or defaults.
    
    Args:
        config_path: Path to the logging configuration file
        default_level: Default logging level if config file not found
    """
    log_config = DEFAULT_LOG_CONFIG.copy()
    
    # Create logs directory if it doesn't exist
    log_dir = Path("logs")
    log_dir.mkdir(exist_ok=True)
    
    # Load configuration file if provided and exists
    if config_path and os.path.exists(config_path):
        try:
            with open(config_path, "rt", encoding="utf-8") as f:
                loaded_config = yaml.safe_load(f.read())
                log_config.update(loaded_config)
        except Exception as e:
            print(f"Error loading logging configuration from {config_path}: {e}")
    
    # Update log level from environment if available
    env_log_level = os.environ.get("LOG_LEVEL", default_level)
    log_config["loggers"][""]["level"] = env_log_level
    log_config["loggers"]["job_scraper"]["level"] = env_log_level
    
    # Configure logging
    try:
        logging.config.dictConfig(log_config)
    except Exception as e:
        print(f"Error configuring logging: {e}")
        # Fall back to basic configuration
        logging.basicConfig(
            level=getattr(logging, env_log_level),
            format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
        )


def get_logger(name: str = "job_scraper", extra: Optional[Dict[str, Any]] = None) -> logging.LoggerAdapter:
    """
    Get a configured logger with optional extra context.
    
    Args:
        name: The name of the logger
        extra: Optional extra context to include in all log messages
        
    Returns:
        A StructuredLogAdapter instance
    """
    extra = extra or {}
    
    # Ensure basic logging is configured if not already
    if not logging.root.handlers:
        setup_logging()
    
    # Get the underlying logger
    logger = logging.getLogger(name)
    
    # Add service name to context
    if "service" not in extra:
        extra["service"] = "job_scraper"
    
    # Return the adapter
    return StructuredLogAdapter(logger, extra)


def log_to_json(logger: logging.Logger, level: str, message: str, **kwargs) -> None:
    """
    Log a message with additional structured data in JSON format.
    
    Args:
        logger: Logger instance
        level: Log level (info, warning, error, etc.)
        message: Log message
        **kwargs: Additional key-value pairs to include in the log
    """
    log_data = {
        "message": message,
        "timestamp": datetime.now().isoformat(),
        **kwargs
    }
    
    log_func = getattr(logger, level.lower())
    log_func(json.dumps(log_data))


# Example usage:
# logger = get_logger("job_scraper.scraper", {"component": "scraper"})
# logger.info("Starting scrape job", extra={"job_id": "123", "source": "linkedin"})
