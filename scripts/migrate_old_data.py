#!/usr/bin/env python3
"""
Script to migrate data from the old database structure to the new one.

This script loads data from the old database and inserts it into the new database
with the updated schema, handling any data transformations needed.
"""

import os
import sys
import logging
import argparse
import json
from datetime import datetime
import pandas as pd
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker
from sqlalchemy.exc import SQLAlchemyError

# Get the project root directory and add it to sys.path
sys.path.insert(0, os.path.abspath(os.path.dirname(os.path.dirname(__file__))))

from app.db.models import Base, Job, Tag, ScraperSearch, SearchResult, ScraperRun

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def connect_to_databases(old_db_url: str, new_db_url: str):
    """
    Connect to both old and new databases and return the connection objects.
    
    Args:
        old_db_url: Connection URL for the old database
        new_db_url: Connection URL for the new database
        
    Returns:
        Tuple of (old_engine, new_engine, new_session)
    """
    logger.info("Connecting to databases...")
    
    try:
        # Connect to old database
        old_engine = create_engine(old_db_url)
        logger.info("Connected to old database")
        
        # Connect to new database
        new_engine = create_engine(new_db_url)
        
        # Create session for new database
        Session = sessionmaker(bind=new_engine)
        new_session = Session()
        logger.info("Connected to new database")
        
        return old_engine, new_engine, new_session
    except SQLAlchemyError as e:
        logger.error(f"Database connection error: {e}")
        sys.exit(1)

def create_new_tables(engine):
    """Create all tables in the new database."""
    logger.info("Creating tables in new database...")
    try:
        Base.metadata.create_all(engine)
        logger.info("Tables created successfully")
    except SQLAlchemyError as e:
        logger.error(f"Error creating tables: {e}")
        sys.exit(1)

def migrate_jobs(old_engine, session):
    """Migrate job data from old to new database."""
    logger.info("Migrating jobs...")
    
    try:
        # Get jobs data from old database
        jobs_df = pd.read_sql("SELECT * FROM jobs", old_engine)
        logger.info(f"Found {len(jobs_df)} jobs in old database")
        
        # Process each job
        job_count = 0
        for _, row in jobs_df.iterrows():
            # Map old schema to new schema
            job = Job(
                source_id=row['job_id'] if 'job_id' in row else str(row['id']),
                title=row['title'],
                company=row['company'],
                location=row.get('location', ''),
                description=row.get('description', ''),
                url=row['url'] if 'url' in row else '',
                salary_min=row.get('salary_min'),
                salary_max=row.get('salary_max'),
                salary_currency=row.get('salary_currency', 'USD'),
                remote=bool(row.get('remote', False)),
                job_type=row.get('job_type', ''),
                experience_level=row.get('experience_level', ''),
                posted_date=row.get('posted_date'),
                source_website=row.get('source', 'unknown'),
                still_active=bool(row.get('active', True)),
                # Convert any JSON or dict fields
                metadata=json.loads(row['metadata']) if isinstance(row.get('metadata'), str) else row.get('metadata', {})
            )
            
            # Add job to session
            session.add(job)
            job_count += 1
            
            # Commit in batches
            if job_count % 100 == 0:
                session.commit()
                logger.info(f"Committed {job_count} jobs")
        
        # Final commit
        session.commit()
        logger.info(f"Successfully migrated {job_count} jobs")
        
    except SQLAlchemyError as e:
        session.rollback()
        logger.error(f"Error migrating jobs: {e}")
        sys.exit(1)
    except Exception as e:
        session.rollback()
        logger.error(f"Unexpected error during job migration: {e}")
        sys.exit(1)

def migrate_tags(old_engine, session):
    """Migrate tags from old to new database."""
    logger.info("Migrating tags...")
    
    try:
        # Check if tags table exists in old database
        with old_engine.connect() as conn:
            result = conn.execute(text(
                "SELECT EXISTS (SELECT FROM information_schema.tables "
                "WHERE table_schema = 'public' AND table_name = 'tags')"
            ))
            has_tags_table = result.scalar()
        
        if not has_tags_table:
            logger.info("No tags table found in old database, skipping")
            return
        
        # Get tags data from old database
        tags_df = pd.read_sql("SELECT * FROM tags", old_engine)
        logger.info(f"Found {len(tags_df)} tags in old database")
        
        # Process each tag
        tag_count = 0
        for _, row in tags_df.iterrows():
            tag = Tag(
                name=row['name'],
                description=row.get('description', '')
            )
            
            # Add tag to session
            session.add(tag)
            tag_count += 1
        
        # Commit tags
        session.commit()
        logger.info(f"Successfully migrated {tag_count} tags")
        
        # Migrate job-tag relationships if they exist
        with old_engine.connect() as conn:
            result = conn.execute(text(
                "SELECT EXISTS (SELECT FROM information_schema.tables "
                "WHERE table_schema = 'public' AND table_name = 'job_tags')"
            ))
            has_job_tags_table = result.scalar()
        
        if has_job_tags_table:
            # Get job-tag relationships
            job_tags_df = pd.read_sql("SELECT * FROM job_tags", old_engine)
            logger.info(f"Found {len(job_tags_df)} job-tag relationships")
            
            # Process each relationship by executing raw SQL for better performance
            with new_engine.begin() as conn:
                for _, row in job_tags_df.iterrows():
                    conn.execute(text(
                        "INSERT INTO job_tags (job_id, tag_id) VALUES (:job_id, :tag_id)"
                    ), {"job_id": row['job_id'], "tag_id": row['tag_id']})
            
            logger.info(f"Successfully migrated job-tag relationships")
        
    except SQLAlchemyError as e:
        session.rollback()
        logger.error(f"Error migrating tags: {e}")
        sys.exit(1)
    except Exception as e:
        session.rollback()
        logger.error(f"Unexpected error during tag migration: {e}")
        sys.exit(1)

def main():
    """Main function to migrate data from old to new database."""
    parser = argparse.ArgumentParser(description="Migrate data from old to new database")
    parser.add_argument(
        "--old-db-url", 
        dest="old_db_url",
        default=os.environ.get("OLD_DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/old_jobsdb"),
        help="Old database connection URL"
    )
    parser.add_argument(
        "--new-db-url", 
        dest="new_db_url",
        default=os.environ.get("DATABASE_URL", "postgresql://postgres:postgres@localhost:5432/jobsdb"),
        help="New database connection URL"
    )
    parser.add_argument(
        "--create-tables",
        dest="create_tables",
        action="store_true",
        help="Create tables in new database before migration"
    )
    
    args = parser.parse_args()
    
    # Connect to databases
    old_engine, new_engine, session = connect_to_databases(args.old_db_url, args.new_db_url)
    
    # Create tables if requested
    if args.create_tables:
        create_new_tables(new_engine)
    
    try:
        # Migrate data
        migrate_jobs(old_engine, session)
        migrate_tags(old_engine, session)
        
        logger.info("Data migration completed successfully")
    except Exception as e:
        logger.error(f"Migration failed: {e}")
        sys.exit(1)
    finally:
        session.close()

if __name__ == "__main__":
    main() 