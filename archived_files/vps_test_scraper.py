#!/usr/bin/env python3
"""
Test script to run the job scraper directly on the VPS
"""
import os
import sys
import asyncio
import json
import logging

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('scraper_test')

async def test_scraper():
    try:
        # Import the scraper module
        sys.path.append('/opt/job-scraper')
        from src.scraper import JobScraper
        
        logger.info("Initializing scraper...")
        scraper = JobScraper(config_path="/opt/job-scraper/config/api_config.yaml")
        
        # Initialize scraper
        logger.info("Attempting to initialize scraper...")
        init_success = await scraper.initialize()
        if not init_success:
            logger.error("Failed to initialize scraper")
            return False
        
        logger.info("Running test scrape with max_pages=1...")
        # Run scraper with a limit of 1 page to test quickly
        results = await scraper.run(max_pages=1)
        
        # Print results
        logger.info(f"Scrape results: {json.dumps(results, indent=2)}")
        
        return True
    except Exception as e:
        logger.error(f"Error testing scraper: {str(e)}")
        import traceback
        logger.error(traceback.format_exc())
        return False

if __name__ == "__main__":
    logger.info("Starting scraper test...")
    asyncio.run(test_scraper())
    logger.info("Scraper test completed")
