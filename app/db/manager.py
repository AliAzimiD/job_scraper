"""
Database connection and management module.

This module provides the DatabaseManager class for handling database connections,
session management, and basic database operations.
"""

import os
import logging
import yaml
from typing import Optional, Tuple, Dict, Any
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker, scoped_session
from sqlalchemy.pool import QueuePool
from sqlalchemy.exc import SQLAlchemyError
from app.db.models import Base

# Configure logging
logger = logging.getLogger(__name__)


class DatabaseManager:
    """
    Manages database connections and operations.
    
    This class handles setting up database connections, providing sessions,
    and performing basic database maintenance operations.
    """
    
    def __init__(self, config_path: Optional[str] = None) -> None:
        """
        Initialize the database manager.
        
        Args:
            config_path: Path to the configuration file. If None, uses environment variables.
        """
        self.engine = None
        self.session_factory = None
        
        try:
            # Get database URL from config file or environment
            db_url = self._get_database_url(config_path)
            db_options = self._get_database_options(config_path)
            
            # Create engine with pooling options
            self.engine = create_engine(
                db_url,
                poolclass=QueuePool,
                pool_size=db_options.get('pool_size', 5),
                max_overflow=db_options.get('max_overflow', 10),
                pool_recycle=db_options.get('pool_recycle', 3600),
                pool_timeout=db_options.get('pool_timeout', 30),
                echo=db_options.get('echo', False)
            )
            
            # Create session factory
            self.session_factory = scoped_session(sessionmaker(bind=self.engine))
            
            logger.info(f"Database connection established: {db_url}")
            
        except Exception as e:
            logger.error(f"Failed to connect to database: {e}")
            raise
    
    def _get_database_url(self, config_path: Optional[str]) -> str:
        """
        Get database URL from config file or environment.
        
        Args:
            config_path: Path to the configuration file.
            
        Returns:
            Database URL string.
        """
        # Try to get from environment first
        db_url = os.environ.get('DATABASE_URL')
        
        # If not found in environment and config_path is provided, try config file
        if not db_url and config_path:
            try:
                with open(config_path, 'r') as file:
                    config = yaml.safe_load(file)
                    
                if config and 'database' in config and 'url' in config['database']:
                    db_url = config['database']['url']
            except Exception as e:
                logger.warning(f"Failed to load config from {config_path}: {e}")
        
        # If still not found, use default
        if not db_url:
            db_url = 'sqlite:///:memory:'
            logger.warning("No database URL found in environment or config, using in-memory SQLite")
        
        return db_url
    
    def _get_database_options(self, config_path: Optional[str]) -> Dict[str, Any]:
        """
        Get database options from config file.
        
        Args:
            config_path: Path to the configuration file.
            
        Returns:
            Dictionary of database options.
        """
        options = {}
        
        # If config_path is provided, try to load options from config file
        if config_path:
            try:
                with open(config_path, 'r') as file:
                    config = yaml.safe_load(file)
                    
                if config and 'database' in config:
                    # Remove 'url' from options if present
                    db_config = config['database'].copy()
                    db_config.pop('url', None)
                    options.update(db_config)
            except Exception as e:
                logger.warning(f"Failed to load database options from {config_path}: {e}")
        
        # Override with environment variables if present
        if os.environ.get('DB_POOL_SIZE'):
            options['pool_size'] = int(os.environ.get('DB_POOL_SIZE'))
        
        if os.environ.get('DB_MAX_OVERFLOW'):
            options['max_overflow'] = int(os.environ.get('DB_MAX_OVERFLOW'))
        
        if os.environ.get('DB_POOL_RECYCLE'):
            options['pool_recycle'] = int(os.environ.get('DB_POOL_RECYCLE'))
        
        if os.environ.get('DB_ECHO') and os.environ.get('DB_ECHO').lower() in ('true', '1', 't'):
            options['echo'] = True
        
        return options
    
    def get_session(self):
        """
        Get a new database session.
        
        Returns:
            SQLAlchemy session object.
        """
        if not self.session_factory:
            raise RuntimeError("Database not initialized")
        
        return self.session_factory()
    
    def create_tables(self) -> None:
        """Create all database tables."""
        if not self.engine:
            raise RuntimeError("Database engine not initialized")
        
        Base.metadata.create_all(self.engine)
        logger.info("Database tables created")
    
    def drop_tables(self) -> None:
        """Drop all database tables."""
        if not self.engine:
            raise RuntimeError("Database engine not initialized")
        
        Base.metadata.drop_all(self.engine)
        logger.info("Database tables dropped")
    
    def health_check(self) -> Tuple[bool, str]:
        """
        Check database connection health.
        
        Returns:
            Tuple of (status: bool, version: str)
        """
        if not self.engine:
            return False, "Database engine not initialized"
        
        try:
            with self.engine.connect() as conn:
                result = conn.execute(text("SELECT version();"))
                version = result.scalar()
                return True, version
        except SQLAlchemyError as e:
            logger.error(f"Database health check failed: {e}")
            return False, str(e)
    
    def close(self) -> None:
        """Close database connections."""
        if self.engine:
            self.engine.dispose()
            logger.info("Database connections closed")
    
    def __enter__(self):
        """Context manager entry."""
        return self
    
    def __exit__(self, exc_type, exc_val, exc_tb):
        """Context manager exit."""
        self.close()
