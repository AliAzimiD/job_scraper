#!/usr/bin/env python3
"""
Test script for running the job scraper interactively.
This allows for testing the scraper without the entire production stack.
"""

import asyncio
import argparse
import logging
import os
import sys
from datetime import datetime

# Add the parent directory to sys.path to allow imports
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '.')))

from src.scraper import JobScraper
from src.db_manager import DatabaseManager
from src.log_setup import get_logger

# Configure logging
logger = get_logger("test_scraper")
logger.setLevel(logging.INFO)

async def run_test_scrape(config_path: str, save_dir: str, pages: int = 1, use_db: bool = True):
    """
    Run a test scraping job.

    Args:
        config_path: Path to the config file
        save_dir: Directory to save job data
        pages: Number of pages to scrape
        use_db: Whether to use the database
    """
    logger.info(f"Starting test scrape with config: {config_path}")
    logger.info(f"Pages to scrape: {pages}, Use DB: {use_db}")
    
    # Initialize DatabaseManager if requested
    db_manager = None
    if use_db:
        # Construct connection string from environment variables or use default
        host = os.environ.get("POSTGRES_HOST", "localhost")
        port = os.environ.get("POSTGRES_PORT", "5432")
        db = os.environ.get("POSTGRES_DB", "jobsdb")
        user = os.environ.get("POSTGRES_USER", "jobuser")
        password = os.environ.get("POSTGRES_PASSWORD", "devpassword")
        
        connection_string = f"postgresql://{user}:{password}@{host}:{port}/{db}"
        logger.info(f"Using database: {host}:{port}/{db}")
        
        db_manager = DatabaseManager(
            connection_string=connection_string,
            min_conn=2,
            max_conn=5
        )
    
    # Initialize and run the scraper
    scraper = JobScraper(
        config_path=config_path,
        save_dir=save_dir,
        db_manager=db_manager
    )
    
    # If pages is specified, update the config
    if pages > 0:
        scraper.scraper_config["max_pages"] = pages
    
    start_time = datetime.now()
    logger.info(f"Scrape started at {start_time}")
    
    try:
        # Initialize the scraper
        await scraper.initialize()
        
        # Run the scraper
        results = await scraper.run()
        
        end_time = datetime.now()
        duration = (end_time - start_time).total_seconds()
        
        logger.info(f"Scrape completed in {duration:.2f} seconds")
        logger.info(f"Results: {results}")
        
        # Print summary
        print("\n" + "="*50)
        print(f"SCRAPE SUMMARY")
        print("="*50)
        print(f"Total jobs scraped: {results.get('total_jobs', 0)}")
        print(f"Pages processed: {results.get('pages_processed', 0)}")
        print(f"Status: {results.get('status', 'unknown')}")
        print(f"Duration: {duration:.2f} seconds")
        print("="*50)
        
        if use_db and db_manager:
            job_count = await db_manager.get_job_count()
            print(f"Total jobs in database: {job_count}")
        
        print("\nData is saved to:", os.path.abspath(save_dir))
        print("="*50)
        
    except Exception as e:
        logger.error(f"Error during test scrape: {str(e)}")
        import traceback
        traceback.print_exc()
    finally:
        # Clean up resources
        if db_manager:
            await db_manager.close()

def parse_arguments():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(description="Test the job scraper.")
    parser.add_argument(
        "--config", 
        default="config/api_config.yaml",
        help="Path to the configuration file"
    )
    parser.add_argument(
        "--save-dir", 
        default="job_data",
        help="Directory to save data"
    )
    parser.add_argument(
        "--pages", 
        type=int, 
        default=1,
        help="Number of pages to scrape (default: 1)"
    )
    parser.add_argument(
        "--no-db", 
        action="store_true",
        help="Don't use the database for storage"
    )
    return parser.parse_args()

if __name__ == "__main__":
    args = parse_arguments()
    asyncio.run(run_test_scrape(
        config_path=args.config,
        save_dir=args.save_dir,
        pages=args.pages,
        use_db=not args.no_db
    )) 