"""
Configuration Manager for Job Scraper Application

This module handles loading and managing configuration settings from YAML files
and environment variables, providing a centralized configuration system.
"""

import json
import logging
import os
import yaml
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional

from .log_setup import get_logger

# Central logger for ConfigManager
logger = get_logger("ConfigManager")


class ConfigManager:
    """Configuration manager for the job scraper application.
    
    This class handles loading configuration from YAML files and environment
    variables, with support for default values and environment-specific overrides.
    """
    
    def __init__(self, config_path: Optional[str] = None):
        """Initialize the configuration manager.
        
        Args:
            config_path: Path to the main configuration file (optional)
        """
        self.config_path = config_path or os.environ.get('APP_CONFIG_PATH', 'config/app_config.yaml')
        self.config = self._load_default_config()
        self._load_from_file()
        self._apply_env_overrides()
    
    def _load_default_config(self) -> Dict[str, Any]:
        """Load default configuration values.
        
        Returns:
            Dict containing default configuration values
        """
        return {
            "app": {
                "environment": "development",
                "debug": False,
                "host": "0.0.0.0",
                "port": 5000,
                "secret_key": os.environ.get("SECRET_KEY", "change-me-in-production"),
                "log_level": "INFO",
                "enable_health_check": True,
                "health_port": 8080,
            },
            "database": {
                "connection_string": "postgresql://postgres:postgres@localhost:5432/jobsdb",
                "schema": "public",
                "pool_size": 10,
                "max_overflow": 20,
                "pool_timeout": 30,
                "pool_recycle": 1800,
            },
            "redis": {
                "host": "localhost",
                "port": 6379,
                "db": 0,
                "password": None,
                "ssl": False,
            },
            "scraper": {
                "config_path": "config/scraper_config.yaml",
                "save_dir": "job_data",
                "batch_size": 100,
                "max_retries": 3,
                "retry_delay": 5,
                "rate_limit": {
                    "requests_per_minute": 60,
                    "concurrent_requests": 5,
                },
                "user_agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
            },
            "monitoring": {
                "enable_prometheus": True,
                "metrics_path": "/metrics",
                "collect_default_metrics": True,
            },
        }
    
    def _load_from_file(self) -> None:
        """Load configuration from the specified YAML file."""
        if os.path.exists(self.config_path):
            try:
                with open(self.config_path, 'r', encoding='utf-8') as f:
                    file_config = yaml.safe_load(f)
                    if file_config:
                        for section in self.config:
                            if section in file_config:
                                self.config[section].update(file_config[section])
            except Exception as e:
                print(f"Error loading config file {self.config_path}: {str(e)}")
    
    def _apply_env_overrides(self) -> None:
        """Apply environment variable overrides to the configuration."""
        # Database configuration
        if os.environ.get("DATABASE_URL"):
            self.config["database"]["connection_string"] = os.environ.get("DATABASE_URL")
        elif os.environ.get("POSTGRES_HOST"):
            db_user = os.environ.get("POSTGRES_USER", "postgres")
            db_password = os.environ.get("POSTGRES_PASSWORD", "postgres")
            db_host = os.environ.get("POSTGRES_HOST", "localhost")
            db_port = os.environ.get("POSTGRES_PORT", "5432")
            db_name = os.environ.get("POSTGRES_DB", "jobsdb")
            
            # If password is in a file, read it
            pw_file = os.environ.get("POSTGRES_PASSWORD_FILE")
            if pw_file and os.path.exists(pw_file):
                with open(pw_file, "r", encoding="utf-8") as pf:
                    db_password = pf.read().strip()
            
            self.config["database"]["connection_string"] = (
                f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"
            )
        
        # Redis configuration
        if os.environ.get("REDIS_URL"):
            self.config["redis"]["url"] = os.environ.get("REDIS_URL")
        elif os.environ.get("REDIS_HOST"):
            self.config["redis"]["host"] = os.environ.get("REDIS_HOST")
            if os.environ.get("REDIS_PORT"):
                self.config["redis"]["port"] = int(os.environ.get("REDIS_PORT"))
            if os.environ.get("REDIS_PASSWORD"):
                self.config["redis"]["password"] = os.environ.get("REDIS_PASSWORD")
        
        # App configuration
        if os.environ.get("ENVIRONMENT"):
            self.config["app"]["environment"] = os.environ.get("ENVIRONMENT")
        if os.environ.get("LOG_LEVEL"):
            self.config["app"]["log_level"] = os.environ.get("LOG_LEVEL")
        if os.environ.get("FLASK_DEBUG"):
            self.config["app"]["debug"] = os.environ.get("FLASK_DEBUG").lower() == "true"
        if os.environ.get("FLASK_HOST"):
            self.config["app"]["host"] = os.environ.get("FLASK_HOST")
        if os.environ.get("FLASK_PORT"):
            self.config["app"]["port"] = int(os.environ.get("FLASK_PORT"))
        if os.environ.get("SECRET_KEY"):
            self.config["app"]["secret_key"] = os.environ.get("SECRET_KEY")
        
        # Scraper configuration
        if os.environ.get("SCRAPER_CONFIG_PATH"):
            self.config["scraper"]["config_path"] = os.environ.get("SCRAPER_CONFIG_PATH")
        if os.environ.get("SAVE_DIR"):
            self.config["scraper"]["save_dir"] = os.environ.get("SAVE_DIR")
        if os.environ.get("MAX_RETRIES"):
            self.config["scraper"]["max_retries"] = int(os.environ.get("MAX_RETRIES"))
    
    def get(self, key: str, default: Any = None) -> Any:
        """Get a configuration value by key path.
        
        Args:
            key: Dot-separated path to the configuration value (e.g., 'database.host')
            default: Default value to return if the key is not found
            
        Returns:
            The configuration value or the default value if not found
        """
        keys = key.split('.')
        value = self.config
        
        for k in keys:
            if isinstance(value, dict) and k in value:
                value = value[k]
            else:
                return default
        
        return value
    
    def get_all(self) -> Dict[str, Any]:
        """Get the entire configuration.
        
        Returns:
            Complete configuration dictionary
        """
        return self.config


# Create a singleton instance
config_manager = ConfigManager()


def get_config() -> ConfigManager:
    """Get the configuration manager instance.
    
    Returns:
        ConfigManager instance
    """
    return config_manager
