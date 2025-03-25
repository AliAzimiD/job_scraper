"""
Database package for the Job Scraper application.

This package handles database connections and operations.
"""

import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, scoped_session
from sqlalchemy.ext.declarative import declarative_base

# Create a base class for declarative models
Base = declarative_base()

# Global session factory
Session = None

def init_db(app):
    """
    Initialize the database connection.
    
    Args:
        app: Flask application
    """
    global Session
    
    # Get database URL from config or environment
    database_url = app.config.get('DATABASE_URL') or os.getenv('DATABASE_URL')
    
    if not database_url:
        app.logger.warning(
            "No DATABASE_URL found in config or environment. "
            "Using sqlite:///jobscraper.db as fallback."
        )
        database_url = 'sqlite:///jobscraper.db'
    
    # Create engine with connection pooling settings
    engine = create_engine(
        database_url,
        pool_pre_ping=True,
        pool_size=5,
        max_overflow=10,
        pool_recycle=3600,
    )
    
    # Create session factory
    session_factory = sessionmaker(bind=engine)
    Session = scoped_session(session_factory)
    
    # Import models after Base is defined
    from app.db.models import Job, ScraperRun  # noqa
    
    # Create tables
    @app.before_first_request
    def create_tables():
        Base.metadata.create_all(bind=engine)

def get_session():
    """
    Get a new database session.
    
    Returns:
        SQLAlchemy session object
    """
    if Session is None:
        raise RuntimeError("Database not initialized. Call init_db first.")
    return Session()

def close_session(session):
    """
    Close a database session.
    
    Args:
        session: SQLAlchemy session to close
    """
    if session:
        session.close()
