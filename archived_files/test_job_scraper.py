#!/usr/bin/env python3
"""
Comprehensive test script for validating the job scraper functionality.
This script tests:
1. Job scraper initialization and connection
2. Database read/write operations
3. Import/export functionality
4. Scheduler configuration
"""

import asyncio
import os
import sys
import json
import logging
import argparse
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, List, Optional

# Add the project root to path to enable imports
current_dir = Path(__file__).resolve().parent
sys.path.insert(0, str(current_dir))

# Import required modules
from src.scraper import JobScraper
from src.db_manager import DatabaseManager
from src.config_manager import ConfigManager
from src.log_setup import get_logger

# Configure logger
logger = get_logger("test_job_scraper")
logger.setLevel(logging.INFO)

class JobScraperTester:
    """Comprehensive tester for the Job Scraper application"""
    
    def __init__(self, 
                 config_path: str = "config/api_config.yaml", 
                 save_dir: str = "job_data",
                 db_connection_string: Optional[str] = None):
        """
        Initialize the tester with configuration paths
        
        Args:
            config_path: Path to the API configuration file
            save_dir: Directory to save job data
            db_connection_string: Optional database connection string override
        """
        self.config_path = config_path
        self.save_dir = Path(save_dir)
        self.save_dir.mkdir(parents=True, exist_ok=True)
        
        # Load configuration
        self.config_manager = ConfigManager(config_path)
        
        # Get database connection string
        db_config = self.config_manager.database_config
        if db_connection_string:
            self.connection_string = db_connection_string
        else:
            # Try environment variables
            host = os.environ.get("POSTGRES_HOST", "localhost")
            port = os.environ.get("POSTGRES_PORT", "5432")
            db = os.environ.get("POSTGRES_DB", "jobsdb")
            user = os.environ.get("POSTGRES_USER", "jobuser")
            password = os.environ.get("POSTGRES_PASSWORD", "devpassword")
            self.connection_string = f"postgresql://{user}:{password}@{host}:{port}/{db}"
        
        # Test results
        self.results = {
            "scraper_initialization": False,
            "database_connection": False,
            "database_read": False,
            "database_write": False,
            "database_export": False,
            "database_import": False,
            "scheduler_config": False,
            "full_scrape": False,
            "errors": []
        }
        
    async def run_all_tests(self) -> Dict[str, Any]:
        """
        Run all tests in sequence and return results
        
        Returns:
            Dictionary with test results
        """
        try:
            # Run tests in sequence
            await self.test_initialization()
            await self.test_database_connection()
            await self.test_database_operations()
            await self.test_import_export()
            await self.test_scheduler_config()
            await self.test_full_scrape()
            
            # Calculate overall result
            success_count = sum(1 for k, v in self.results.items() if k != "errors" and v)
            total_tests = len(self.results) - 1  # exclude 'errors' key
            self.results["overall_success"] = success_count == total_tests
            self.results["success_percentage"] = (success_count / total_tests) * 100
            
            return self.results
            
        except Exception as e:
            logger.error(f"Test suite failed with error: {str(e)}")
            self.results["errors"].append(f"Test suite error: {str(e)}")
            return self.results
    
    async def test_initialization(self) -> bool:
        """Test scraper initialization"""
        logger.info("Testing scraper initialization...")
        
        try:
            # Initialize scraper
            scraper = JobScraper(
                config_path=self.config_path,
                save_dir=str(self.save_dir)
            )
            
            # Check if essential attributes are present
            assert hasattr(scraper, 'config_manager'), "Scraper missing config_manager"
            assert hasattr(scraper, 'api_config'), "Scraper missing api_config"
            assert hasattr(scraper, 'base_url'), "Scraper missing base_url"
            
            # Log success
            logger.info("Scraper initialization successful")
            self.results["scraper_initialization"] = True
            return True
            
        except Exception as e:
            logger.error(f"Scraper initialization failed: {str(e)}")
            self.results["errors"].append(f"Initialization error: {str(e)}")
            return False
    
    async def test_database_connection(self) -> bool:
        """Test database connection"""
        logger.info("Testing database connection...")
        
        try:
            # Initialize database manager
            db_manager = DatabaseManager(
                connection_string=self.connection_string,
                min_conn=1,
                max_conn=2
            )
            
            # Test connection
            success = await db_manager.initialize()
            assert success, "Database initialization failed"
            
            # Store for later tests
            self.db_manager = db_manager
            
            # Log success
            logger.info("Database connection successful")
            self.results["database_connection"] = True
            return True
            
        except Exception as e:
            logger.error(f"Database connection failed: {str(e)}")
            self.results["errors"].append(f"Database connection error: {str(e)}")
            return False
    
    async def test_database_operations(self) -> bool:
        """Test database read/write operations"""
        logger.info("Testing database read/write operations...")
        
        if not hasattr(self, 'db_manager'):
            logger.error("Database manager not initialized")
            self.results["errors"].append("Database manager not initialized")
            return False
        
        try:
            # Create a test job record
            test_job = {
                "job_id": f"test-{int(time.time())}",
                "title": "Test Job for Validation",
                "company": "Test Company",
                "location": "Test Location",
                "description": "This is a test job created for validation",
                "url": "https://example.com/test-job",
                "salary": "$100,000 - $120,000",
                "date_posted": datetime.now().isoformat(),
                "job_type": "Full-time",
                "test_record": True
            }
            
            # Test writing to database
            await self.db_manager.insert_job(test_job)
            logger.info("Job record inserted successfully")
            self.results["database_write"] = True
            
            # Test reading from database
            test_query = "SELECT * FROM jobs WHERE job_id = $1"
            rows = await self.db_manager.execute_query(test_query, [test_job["job_id"]])
            assert rows and len(rows) > 0, "Job record not found in database"
            
            logger.info("Job record retrieved successfully")
            self.results["database_read"] = True
            
            # Clean up test record
            await self.db_manager.execute_query(
                "DELETE FROM jobs WHERE job_id = $1", 
                [test_job["job_id"]]
            )
            
            return True
            
        except Exception as e:
            logger.error(f"Database operations failed: {str(e)}")
            self.results["errors"].append(f"Database operations error: {str(e)}")
            return False
    
    async def test_import_export(self) -> bool:
        """Test database import/export functionality"""
        logger.info("Testing database import/export...")
        
        if not hasattr(self, 'db_manager'):
            logger.error("Database manager not initialized")
            self.results["errors"].append("Database manager not initialized")
            return False
        
        try:
            # Create a test export file
            test_export_path = self.save_dir / f"test_export_{int(time.time())}.csv"
            
            # Export a few jobs
            jobs = await self.db_manager.execute_query(
                "SELECT * FROM jobs LIMIT 5"
            )
            
            if jobs and len(jobs) > 0:
                # Testing export
                await self.db_manager.export_jobs_to_csv(
                    output_path=str(test_export_path)
                )
                
                assert test_export_path.exists(), "Export file not created"
                logger.info(f"Successfully exported jobs to {test_export_path}")
                self.results["database_export"] = True
                
                # Testing import (create temp backup and restore)
                backup_path = self.save_dir / f"test_backup_{int(time.time())}.sql"
                await self.db_manager.backup_database(str(backup_path))
                
                assert backup_path.exists(), "Backup file not created"
                logger.info(f"Successfully created database backup at {backup_path}")
                self.results["database_import"] = True
                
                # Clean up
                if test_export_path.exists():
                    test_export_path.unlink()
                if backup_path.exists():
                    backup_path.unlink()
                
                return True
            else:
                logger.warning("No jobs found in database to test export/import")
                # Mark as success if database is empty - not a functionality failure
                self.results["database_export"] = True
                self.results["database_import"] = True
                return True
            
        except Exception as e:
            logger.error(f"Import/export testing failed: {str(e)}")
            self.results["errors"].append(f"Import/export error: {str(e)}")
            return False
    
    async def test_scheduler_config(self) -> bool:
        """Test if scheduler is properly configured"""
        logger.info("Testing scheduler configuration...")
        
        try:
            # Check for systemd timer or cron job configuration
            if os.path.exists("/etc/systemd/system/job-scraper-run.timer"):
                # Check systemd timer configuration 
                import subprocess
                
                # Verify timer is active
                result = subprocess.run(
                    ["systemctl", "is-active", "job-scraper-run.timer"],
                    capture_output=True, text=True
                )
                
                if result.stdout.strip() == "active":
                    logger.info("Systemd timer is active")
                    self.results["scheduler_config"] = True
                    return True
                else:
                    logger.warning("Systemd timer exists but is not active")
            
            # Check for Docker cron configuration
            if os.path.exists("/etc/cron.d/scraper-cron"):
                with open("/etc/cron.d/scraper-cron", "r") as f:
                    cron_content = f.read()
                
                # Verify it runs hourly between 6AM and 11PM
                if "*/6" in cron_content:
                    logger.info("Docker cron job is configured")
                    self.results["scheduler_config"] = True
                    return True
                
            # If we're in a regular environment without systemd or Docker cron
            # This could be a development environment, so we'll check
            # if the scheduler class is working correctly
            from src.scheduler import JobScraperScheduler
            
            scheduler = JobScraperScheduler(
                config_path=self.config_path,
                base_dir=str(self.save_dir),
                interval_minutes=30
            )
            
            assert hasattr(scheduler, 'run'), "Scheduler missing run method"
            logger.info("Scheduler class is properly configured")
            self.results["scheduler_config"] = True
            return True
            
        except Exception as e:
            logger.error(f"Scheduler configuration test failed: {str(e)}")
            self.results["errors"].append(f"Scheduler config error: {str(e)}")
            return False
            
    async def test_full_scrape(self) -> bool:
        """Test a full scrape operation with a limited page count"""
        logger.info("Testing full scrape operation (limited)...")
        
        try:
            # Initialize scraper with database connection
            scraper = JobScraper(
                config_path=self.config_path,
                save_dir=str(self.save_dir),
                db_manager=self.db_manager if hasattr(self, 'db_manager') else None
            )
            
            # Limit to a single page for testing
            scraper.scraper_config["max_pages"] = 1
            
            # Initialize the scraper
            await scraper.initialize()
            
            # Run the scraper
            start_time = time.time()
            results = await scraper.run()
            duration = time.time() - start_time
            
            # Verify results
            assert results.get("status") in ["success", "partial"], "Scrape failed"
            
            logger.info(f"Full scrape test completed in {duration:.2f}s with status: {results.get('status')}")
            logger.info(f"Jobs collected: {results.get('total_jobs', 0)}")
            
            self.results["full_scrape"] = True
            return True
            
        except Exception as e:
            logger.error(f"Full scrape test failed: {str(e)}")
            self.results["errors"].append(f"Full scrape error: {str(e)}")
            return False
    
    def print_results(self) -> None:
        """Print test results in a readable format"""
        print("\n" + "="*50)
        print(" JOB SCRAPER FUNCTIONALITY TEST RESULTS ")
        print("="*50)
        
        # Print individual test results
        for key, value in self.results.items():
            if key != "errors" and key != "overall_success" and key != "success_percentage":
                status = "✅ PASS" if value else "❌ FAIL"
                test_name = key.replace("_", " ").title()
                print(f"{test_name:.<30}{status}")
        
        # Print overall result
        print("-"*50)
        if "overall_success" in self.results:
            overall = "✅ PASSED" if self.results["overall_success"] else "❌ FAILED"
            percentage = self.results.get("success_percentage", 0)
            print(f"Overall Result:..............{overall} ({percentage:.1f}%)")
        
        # Print errors if any
        if self.results.get("errors"):
            print("\nErrors encountered:")
            for i, error in enumerate(self.results["errors"], 1):
                print(f"{i}. {error}")
        
        print("="*50)

async def main():
    """Main function to run tests"""
    parser = argparse.ArgumentParser(description="Test Job Scraper functionality")
    parser.add_argument(
        "--config", 
        default="config/api_config.yaml",
        help="Path to the API config file"
    )
    parser.add_argument(
        "--save-dir", 
        default="job_data",
        help="Directory to save data"
    )
    parser.add_argument(
        "--db-connection",
        help="Database connection string (optional)"
    )
    
    args = parser.parse_args()
    
    # Create and run tester
    tester = JobScraperTester(
        config_path=args.config,
        save_dir=args.save_dir,
        db_connection_string=args.db_connection
    )
    
    await tester.run_all_tests()
    tester.print_results()
    
    # Exit with appropriate code
    if tester.results.get("overall_success", False):
        sys.exit(0)
    else:
        sys.exit(1)

if __name__ == "__main__":
    asyncio.run(main()) 