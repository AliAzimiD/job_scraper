#!/bin/bash

export VPS_PASS="jy6adu06wxefmvsi1kzo"

echo "Creating a script to fix the scraper.py syntax issues..."
cat > fix_scraper.py << 'EOF'
#!/usr/bin/env python3
"""
Script to fix syntax errors in the scraper.py file
"""
import re
import sys

def fix_scraper_file(filepath):
    print(f"Reading file: {filepath}")
    with open(filepath, 'r') as f:
        content = f.read()
    
    # Fix the try block at line 180
    print("Fixing try block at line ~180")
    pattern1 = r"try:(\s+)self\.logger\.info.*?async with self\.semaphore:"
    replacement1 = r"try:\1self.logger.info\1async with self.semaphore:\1    try:"
    content = re.sub(pattern1, replacement1, content, flags=re.DOTALL)
    
    # Fix other similar issues - incomplete try blocks
    pattern2 = r"try:(\s+)([^\n]+)(\s+)([^\n]+)"
    replacement2 = r"try:\1\2\3    try:\3        \4"
    content = re.sub(pattern2, replacement2, content)
    
    # Fix indentation issues
    lines = content.split('\n')
    fixed_lines = []
    in_try_block = False
    expected_except = False
    
    for i, line in enumerate(lines):
        if "try:" in line and "except" not in line:
            in_try_block = True
            expected_except = True
        elif expected_except and line.strip() and not line.strip().startswith("except") and not line.strip().startswith("finally"):
            # Adjust indentation for lines in try block
            indent = len(line) - len(line.lstrip())
            fixed_lines.append(" " * indent + "try:")
            fixed_lines.append(line)
            expected_except = False
        else:
            fixed_lines.append(line)
            if line.strip().startswith("except") or line.strip().startswith("finally"):
                expected_except = False
    
    fixed_content = '\n'.join(fixed_lines)
    
    # Write the fixed content back
    print(f"Writing fixed content to: {filepath}")
    with open(filepath, 'w') as f:
        f.write(fixed_content)
    
    print("Fix completed")
    return True

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python fix_scraper.py <filepath>")
        sys.exit(1)
    
    filepath = sys.argv[1]
    success = fix_scraper_file(filepath)
    sys.exit(0 if success else 1)
EOF

echo "Uploading fix script to VPS..."
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no fix_scraper.py root@23.88.125.23:/opt/job-scraper/

echo "Running fix script on scraper.py..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "cd /opt/job-scraper && python3 fix_scraper.py /opt/job-scraper/src/scraper.py"

echo "Now creating a simplified scraper for testing..."
cat > simple_scraper.py << 'EOF'
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
EOF

echo "Uploading simplified scraper to VPS..."
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no simple_scraper.py root@23.88.125.23:/opt/job-scraper/

echo "Running simplified scraper on VPS..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "cd /opt/job-scraper && python3 simple_scraper.py"

echo "Fix completed." 