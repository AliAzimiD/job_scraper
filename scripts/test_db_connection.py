#!/usr/bin/env python3
"""
Test script to verify database connection.
"""

import os
import sys
import logging
import argparse
from sqlalchemy import create_engine, text
from sqlalchemy.exc import SQLAlchemyError

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def test_connection(database_url: str) -> None:
    """Test database connection with the provided URL."""
    logger.info(f"Testing connection to database...")
    
    try:
        # Create engine
        engine = create_engine(database_url)
        
        # Test connection
        with engine.connect() as connection:
            result = connection.execute(text("SELECT version();"))
            version = result.scalar()
            
        logger.info(f"Connection successful! Database version: {version}")
        
        # Test table listing
        with engine.connect() as connection:
            result = connection.execute(text(
                "SELECT table_name FROM information_schema.tables "
                "WHERE table_schema='public'"
            ))
            tables = [row[0] for row in result]
        
        if tables:
            logger.info(f"Found {len(tables)} tables: {', '.join(tables)}")
        else:
            logger.info("No tables found in database")
            
        return True
        
    except SQLAlchemyError as e:
        logger.error(f"Database connection error: {e}")
        return False
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        return False

def main() -> None:
    """Main function to test database connection."""
    parser = argparse.ArgumentParser(description="Test Database Connection")
    parser.add_argument(
        "--url", 
        dest="database_url",
        default=os.environ.get(
            "DATABASE_URL", 
            "postgresql://postgres:postgres@localhost:5432/jobsdb"
        ),
        help="Database connection URL"
    )
    
    args = parser.parse_args()
    
    success = test_connection(args.database_url)
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main() 