"""
Database initialization module for the Job Scraper application.
"""
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import scoped_session, sessionmaker
from sqlalchemy.ext.declarative import declarative_base

Base = declarative_base()
Session = None

def init_db(app):
    """Initialize the database connection."""
    global Session
    
    # Get database URL from environment variable or app config
    database_url = app.config.get('DATABASE_URL')
    
    # Create database engine
    engine = create_engine(
        database_url,
        pool_size=5,
        max_overflow=10,
        pool_recycle=3600,
        pool_pre_ping=True
    )
    
    # Create session factory
    session_factory = sessionmaker(bind=engine)
    Session = scoped_session(session_factory)
    
    # Import models to ensure they're registered with the Base
    from app.db.models import Job, ScraperRun
    
    # Create all tables
    with app.app_context():
        Base.metadata.create_all(bind=engine)
    
    app.logger.info("Database initialized successfully")

def get_session():
    """Get a new database session."""
    if Session is None:
        raise RuntimeError("Database not initialized. Call init_db first.")
    return Session()

def close_session(session):
    """Close a database session."""
    if session:
        session.close() 