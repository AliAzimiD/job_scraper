#!/usr/bin/env python3
"""
Simplified job scraper for testing
"""
import os
import sys
import asyncio
import json
import logging
import aiohttp
from datetime import datetime

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger('simple_scraper')

class SimpleJobScraper:
    def __init__(self, config_path=None):
        self.base_url = "https://jobinja.ir/api/jobs"
        self.headers = {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
            "Accept": "application/json",
            "Content-Type": "application/json"
        }
        self.save_dir = "job_data"
    
    async def initialize(self):
        """Initialize the scraper"""
        logger.info("Initializing scraper...")
        return True
    
    def create_payload(self, page=1):
        """Create a payload for the API request"""
        return {
            "page": page,
            "filters": {}
        }
    
    async def fetch_page(self, page=1):
        """Fetch a page of job listings"""
        logger.info(f"Fetching page {page}")
        try:
            async with aiohttp.ClientSession() as session:
                json_body = self.create_payload(page)
                async with session.post(
                    self.base_url,
                    headers=self.headers,
                    json=json_body,
                    timeout=30
                ) as response:
                    if response.status != 200:
                        logger.warning(f"Non-200 response: {response.status}")
                        return None
                    
                    # Parse the response
                    data = await response.json()
                    return data
        except Exception as e:
            logger.error(f"Error fetching page {page}: {str(e)}")
            return None
    
    async def run(self, max_pages=1):
        """Run the scraper for a specified number of pages"""
        logger.info(f"Starting scrape with max_pages={max_pages}")
        results = {
            "total_jobs": 0,
            "pages_processed": 0,
            "start_time": datetime.now().isoformat(),
            "end_time": None,
            "status": "running"
        }
        
        try:
            jobs_found = 0
            
            for page in range(1, max_pages + 1):
                data = await self.fetch_page(page)
                
                if not data:
                    logger.warning(f"No data returned for page {page}")
                    continue
                
                if "data" in data and "jobs" in data["data"]:
                    jobs = data["data"]["jobs"]
                    jobs_found += len(jobs)
                    logger.info(f"Found {len(jobs)} jobs on page {page}")
                else:
                    logger.warning(f"Unexpected data structure on page {page}")
            
            results["total_jobs"] = jobs_found
            results["pages_processed"] = max_pages
            results["status"] = "completed"
        except Exception as e:
            logger.error(f"Error during scrape: {str(e)}")
            results["status"] = "failed"
        finally:
            results["end_time"] = datetime.now().isoformat()
        
        return results

async def main():
    scraper = SimpleJobScraper()
    await scraper.initialize()
    results = await scraper.run(max_pages=1)
    print(json.dumps(results, indent=2))

if __name__ == "__main__":
    asyncio.run(main())
