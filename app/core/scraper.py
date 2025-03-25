"""
Job scraper module for the Job Scraper application.

This module handles the core scraping functionality, including fetching
job listings from various sources, processing them, and saving them to
the database.
"""

import asyncio
import os
import json
import uuid
import time
import logging
import traceback
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, List, Optional, Set, Tuple, AsyncGenerator

import aiohttp
from aiohttp import ClientTimeout
import asyncpg

from app.core.exceptions import (
    JobScraperError, 
    ScraperConnectionError, 
    ScraperParsingError
)
from app.db import get_session
from app.db.models import Job, ScraperRun


class JobScraper:
    """
    Main scraper class for fetching job listings from various sources.
    
    This class handles the entire scraping process, from fetching job
    listings to processing them and saving them to the database.
    """
    
    def __init__(self, 
                 base_url: str = "https://api.example.com/jobs",
                 config: Optional[Dict[str, Any]] = None) -> None:
        """
        Initialize the scraper with configuration and setup.
        
        Args:
            base_url: Base URL for the API to scrape
            config: Configuration dictionary for the scraper
        """
        # Basic configuration
        self.base_url = base_url
        self.config = config or {}
        
        # Set up logger
        self.logger = logging.getLogger("jobscraper")
        
        # Headers for requests
        self.headers = self.config.get("headers", {
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
                          "(KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
            "Accept": "application/json",
            "Content-Type": "application/json"
        })
        
        # Concurrency control
        self.max_concurrent = self.config.get("max_concurrent_requests", 5)
        self.semaphore = asyncio.Semaphore(self.max_concurrent)
        
        # Rate limiting
        self.request_interval = self.config.get("request_interval", 1.0)
        
        # Status tracking
        self.status = {
            "running": False,
            "status": "idle",
            "start_time": None,
            "end_time": None,
            "jobs_found": 0,
            "jobs_added": 0,
            "progress": 0,
            "error": None
        }
        
        # Create scraper run in database
        self.run_id = str(uuid.uuid4())
        
        # File storage
        self.current_batch = 0
        self.processed_dir = Path("job_data/processed")
        self.processed_dir.mkdir(parents=True, exist_ok=True)
        
        # Database state
        self.db_enabled = True
        self.db_manager = None
    
    async def initialize(self) -> bool:
        """
        Initialize the scraper, setting up any necessary resources.
        
        Returns:
            True if initialization was successful, False otherwise
        """
        try:
            self.logger.info("Initializing JobScraper")
            # Nothing to initialize in this simple implementation
            return True
        except Exception as e:
            self.logger.error(f"Error initializing scraper: {str(e)}")
            return False
    
    def create_payload(self, page: int = 1) -> Dict[str, Any]:
        """
        Create the payload for the API request.
        
        Args:
            page: Page number to request
            
        Returns:
            Dictionary with the API request payload
        """
        return {
            "page": page,
            "pageSize": 25,
            "filters": {}
        }
    
    async def fetch_page(self, page: int) -> Optional[Dict[str, Any]]:
        """
        Fetch a page of job listings from the API.
        
        Args:
            page: Page number to fetch
            
        Returns:
            Response data if successful, None otherwise
            
        Raises:
            ScraperConnectionError: If there's a connection issue
            ScraperParsingError: If there's an issue parsing the response
        """
        try:
            self.logger.info(f"Fetching page {page} from {self.base_url}")
            
            async with self.semaphore:
                try:
                    start_time = time.time()
                    
                    # Get timeout from config or use default
                    timeout = ClientTimeout(
                        total=self.config.get("timeout", 30)
                    )
                    
                    # Create payload
                    json_body = self.create_payload(page)
                    
                    # Make the request
                    async with aiohttp.ClientSession(timeout=timeout) as session:
                        async with session.post(
                            self.base_url,
                            headers=self.headers,
                            json=json_body,
                            raise_for_status=True
                        ) as response:
                            # Check response status
                            if response.status != 200:
                                self.logger.warning(f"Non-200 response: {response.status} on page {page}")
                                return None
                            
                            # Try to parse JSON response
                            try:
                                data = await response.json()
                                
                                # Validate basic structure of the response
                                if not isinstance(data, dict):
                                    self.logger.warning(f"Response not a dictionary on page {page}")
                                    return None
                                
                                # Measure request time
                                request_time = time.time() - start_time
                                self.logger.debug(f"Page {page} fetched in {request_time:.2f}s")
                                
                                return data
                            except json.JSONDecodeError as e:
                                self.logger.error(f"JSON parsing error on page {page}: {str(e)}")
                                # Get first part of the response text for debugging
                                text = await response.text()
                                self.logger.error(f"Response text (first 200 chars): {text[:200]}")
                                raise ScraperParsingError(f"JSON parsing error: {str(e)}")
                except asyncio.TimeoutError:
                    self.logger.error(f"Timeout fetching page {page}")
                    raise ScraperConnectionError(f"Timeout fetching page {page}")
                except aiohttp.ClientError as e:
                    self.logger.error(f"HTTP client error on page {page}: {str(e)}")
                    raise ScraperConnectionError(f"HTTP client error: {str(e)}")
        except Exception as e:
            self.logger.error(f"Unexpected error fetching page {page}: {str(e)}")
            if isinstance(e, (ScraperConnectionError, ScraperParsingError)):
                raise
            raise JobScraperError(f"Error fetching page {page}: {str(e)}")
        
        return None
    
    async def process_jobs(self, jobs: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Process jobs data from the API and validate it.
        
        Args:
            jobs: List of job dictionaries to process
            
        Returns:
            List of processed job dictionaries
        """
        processed_jobs = []
        
        for job in jobs:
            try:
                # Ensure job has all required fields
                required_fields = ["id", "title", "company"]
                if not all(field in job for field in required_fields):
                    self.logger.warning(f"Skipping job missing required fields: {job.get('id', 'unknown')}")
                    continue
                
                # Clean and process the job data
                processed_job = self._clean_job_data(job)
                
                # Add to processed jobs if valid
                if self._validate_job(processed_job):
                    processed_jobs.append(processed_job)
                else:
                    self.logger.warning(f"Skipping invalid job: {job.get('id', 'unknown')}")
            except Exception as e:
                self.logger.error(f"Error processing job {job.get('id', 'unknown')}: {str(e)}")
                continue
        
        return processed_jobs
    
    def _clean_job_data(self, job: Dict[str, Any]) -> Dict[str, Any]:
        """
        Clean and standardize job data.
        
        Args:
            job: Raw job data
            
        Returns:
            Cleaned job data
        """
        # Create a copy to avoid modifying the original
        cleaned = job.copy()
        
        # Convert date strings to proper format if needed
        if "posted_date" in cleaned and isinstance(cleaned["posted_date"], str):
            try:
                # Try to parse and standardize the date format
                dt = datetime.fromisoformat(cleaned["posted_date"].replace("Z", "+00:00"))
                cleaned["posted_date"] = dt.isoformat()
            except ValueError:
                # If parsing fails, keep the original string
                pass
        
        # Ensure required fields have proper types
        if "id" in cleaned and not isinstance(cleaned["id"], str):
            cleaned["id"] = str(cleaned["id"])
        
        # Handle salary data
        if "salary" in cleaned:
            salary = cleaned["salary"]
            
            # Convert salary to string if it's a complex object
            if isinstance(salary, dict) and not any(k in salary for k in ["min", "max", "text"]):
                try:
                    cleaned["salary"] = json.dumps(salary, ensure_ascii=False)
                except Exception:
                    cleaned["salary"] = str(salary)
            
            # If salary is a list, convert to string
            if isinstance(salary, list):
                try:
                    cleaned["salary"] = json.dumps(salary, ensure_ascii=False)
                except Exception:
                    cleaned["salary"] = str(salary)
        
        return cleaned
    
    def _validate_job(self, job: Dict[str, Any]) -> bool:
        """
        Validate that a job has all required fields and proper data types.
        
        Args:
            job: Job data to validate
            
        Returns:
            True if valid, False otherwise
        """
        # Check required fields
        required_fields = ["id", "title", "company"]
        for field in required_fields:
            if field not in job:
                return False
            
            # Ensure fields are not empty
            if job[field] is None or (isinstance(job[field], str) and not job[field].strip()):
                return False
        
        return True
    
    async def save_jobs(self, jobs: List[Dict[str, Any]]) -> int:
        """
        Save jobs to the database.
        
        Args:
            jobs: List of job dictionaries to save
            
        Returns:
            Number of jobs saved
        """
        if not jobs:
            return 0
        
        processed_count = 0
        batch_id = str(uuid.uuid4())
        start_time = time.time()
        
        # Save to database if enabled
        if self.db_enabled and self.db_manager:
            try:
                self.logger.info(f"Saving {len(jobs)} jobs to DB in batch_id={batch_id}")
                
                # Try database insertion with retry logic
                retries = 0
                max_retries = self.config.get("db_retries", 3)
                initial_backoff = self.config.get("retry_initial_delay", 1.0)
                backoff_factor = self.config.get("retry_backoff_factor", 2)
                
                while retries <= max_retries:
                    try:
                        # Get DB session
                        session = get_session()
                        try:
                            # Get current time for all jobs
                            now = datetime.utcnow()
                            
                            # Create Job models
                            job_models = []
                            for job_data in jobs:
                                # Convert API data to ORM model
                                job = Job(
                                    source_id=job_data["id"],
                                    title=job_data["title"],
                                    company=job_data["company"],
                                    description=job_data.get("description", ""),
                                    url=job_data.get("url", ""),
                                    location=job_data.get("location", ""),
                                    job_type=job_data.get("job_type", ""),
                                    remote=job_data.get("remote", False),
                                    created_at=now,
                                    updated_at=now,
                                    source_website="api.example.com",
                                    still_active=True,
                                    scraper_run_id=self.run_id
                                )
                                job_models.append(job)
                            
                            # Add all jobs to the session
                            session.add_all(job_models)
                            
                            # Commit the changes
                            session.commit()
                            
                            processed_count = len(job_models)
                            self.logger.info(
                                f"DB upsert complete: {processed_count} jobs inserted/updated for batch {batch_id}"
                            )
                            
                            # Break out of retry loop on success
                            break
                        except Exception as session_error:
                            session.rollback()
                            self.logger.error(f"Database session error: {str(session_error)}")
                            raise
                        finally:
                            session.close()
                        
                    except (asyncpg.exceptions.PostgresConnectionError, asyncpg.exceptions.PostgresError) as conn_error:
                        retries += 1
                        self.logger.warning(f"Database connection error (attempt {retries}/{max_retries}): {str(conn_error)}")
                        
                        if retries > max_retries:
                            self.logger.error(f"Failed to save to database after {max_retries} attempts")
                            raise
                        
                        # Exponential backoff
                        wait_time = initial_backoff * (backoff_factor ** (retries - 1))
                        self.logger.info(f"Retrying in {wait_time:.1f} seconds...")
                        await asyncio.sleep(wait_time)
                    
                    except Exception as db_error:
                        retries += 1
                        if retries > max_retries:
                            self.logger.error(f"Failed to save to database after {max_retries} attempts")
                            raise
                        
                        self.logger.error(f"Database error: {str(db_error)}")
                        
                        # Exponential backoff
                        wait_time = initial_backoff * (backoff_factor ** (retries - 1))
                        self.logger.info(f"Retrying in {wait_time:.1f} seconds...")
                        await asyncio.sleep(wait_time)
            
            except Exception as db_error:
                self.logger.error(f"Database insertion error: {str(db_error)}")
                self.logger.error(traceback.format_exc())
                # Fall through to file storage as backup
        
        # Save to file if DB saving failed or if DB is not enabled
        if processed_count == 0:
            try:
                file_save_start = time.time()
                self.logger.info(f"Saving {len(jobs)} jobs to file (batch {self.current_batch})")
                
                # Create a temporary directory for atomic file operations
                temp_dir = self.processed_dir / "temp"
                temp_dir.mkdir(exist_ok=True)
                
                # Generate a unique batch name
                timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                batch_name = f"batch_{self.current_batch}_{timestamp}"
                
                # Save as JSON (primary format)
                json_temp = temp_dir / f"{batch_name}.json.tmp"
                json_path = self.processed_dir / f"{batch_name}.json"
                
                with open(json_temp, 'w', encoding='utf-8') as f:
                    json.dump(jobs, f, ensure_ascii=False, indent=2)
                
                # Move to final location (atomic operation)
                json_temp.rename(json_path)
                self.logger.debug(f"Saved JSON data to {json_path}")
                file_save_success = True
                
                # Try to save in additional formats for interoperability
                try:
                    import pandas as pd
                    
                    # Normalize the data for pandas
                    normalized_jobs = []
                    for job in jobs:
                        # Create a flattened version of the job
                        norm_job = {
                            "id": job.get("id", ""),
                            "title": job.get("title", ""),
                            "company": job.get("company", ""),
                            "location": job.get("location", ""),
                            "description": job.get("description", "")[:500],  # Truncate description
                            "url": job.get("url", ""),
                            "posted_date": job.get("posted_date", ""),
                            "job_type": job.get("job_type", ""),
                            "remote": job.get("remote", False),
                        }
                        normalized_jobs.append(norm_job)
                    
                    # Create DataFrame
                    df = pd.DataFrame(normalized_jobs)
                    
                    # Save as Parquet
                    parquet_temp = temp_dir / f"{batch_name}.parquet.tmp"
                    parquet_path = self.processed_dir / f"{batch_name}.parquet"
                    try:
                        df.to_parquet(parquet_temp, index=False)
                        parquet_temp.rename(parquet_path)
                        self.logger.debug(f"Saved Parquet data to {parquet_path}")
                    except Exception as e:
                        self.logger.error(f"Error saving Parquet: {str(e)}")
                    
                    # Save as CSV
                    csv_temp = temp_dir / f"{batch_name}.csv.tmp"
                    csv_path = self.processed_dir / f"{batch_name}.csv"
                    try:
                        df.to_csv(csv_temp, index=False, encoding="utf-8")
                        csv_temp.rename(csv_path)
                        self.logger.debug(f"Saved CSV data to {csv_path}")
                    except Exception as e:
                        self.logger.error(f"Error saving CSV: {str(e)}")
                
                except Exception as df_error:
                    self.logger.error(f"Error processing jobs for DataFrame: {str(df_error)}")
                    self.logger.error(traceback.format_exc())
                    # We still count it as success if JSON was saved
                
                self.current_batch += 1
                processed_count = len(jobs)
                
            except Exception as file_error:
                self.logger.error(f"Error saving to file: {str(file_error)}")
                self.logger.error(traceback.format_exc())
                # If we also failed to save to file and had no DB success, we have a problem
                if processed_count == 0:
                    self.logger.error(f"CRITICAL: Failed to save {len(jobs)} jobs to both DB and file!")
        
        # Log processing time
        process_time = time.time() - start_time
        self.logger.debug(f"Saved {processed_count} jobs in {process_time:.2f}s")
        
        return processed_count
    
    async def run(self, max_pages: int = 5) -> Dict[str, Any]:
        """
        Run the scraper to fetch and process job listings.
        
        Args:
            max_pages: Maximum number of pages to scrape
            
        Returns:
            Dictionary with scraping results
        """
        # Don't run if already running
        if self.status["running"]:
            return {
                "success": False,
                "message": "Scraper is already running",
                "status": self.status
            }
        
        # Update status
        start_time = datetime.utcnow()
        self.status = {
            "running": True,
            "status": "running",
            "start_time": start_time.isoformat(),
            "end_time": None,
            "jobs_found": 0,
            "jobs_added": 0,
            "progress": 0,
            "error": None
        }
        
        # Create scraper run record
        session = get_session()
        try:
            scraper_run = ScraperRun(
                run_id=self.run_id,
                start_time=start_time,
                status="running",
                max_pages=max_pages
            )
            session.add(scraper_run)
            session.commit()
        except Exception as e:
            self.logger.error(f"Error creating scraper run record: {str(e)}")
            session.rollback()
        finally:
            session.close()
        
        try:
            total_jobs = 0
            saved_jobs = 0
            
            # Process each page
            for page in range(1, max_pages + 1):
                # Check if we should stop
                if not self.status["running"]:
                    self.logger.info("Scraper was stopped by user")
                    break
                
                # Update progress
                self.status["progress"] = int((page - 1) / max_pages * 100)
                
                # Fetch page
                try:
                    data = await self.fetch_page(page)
                    if not data:
                        self.logger.warning(f"No data returned for page {page}")
                        continue
                    
                    # Extract jobs from response - assuming a structure with 'jobs' key
                    jobs = data.get("jobs", [])
                    if not jobs:
                        self.logger.info(f"No jobs found on page {page}")
                        continue
                    
                    # Process and validate jobs
                    processed_jobs = await self.process_jobs(jobs)
                    
                    # Update counters
                    total_jobs += len(processed_jobs)
                    self.status["jobs_found"] = total_jobs
                    
                    # Save to database
                    saved = await self.save_jobs(processed_jobs)
                    saved_jobs += saved
                    self.status["jobs_added"] = saved_jobs
                    
                    self.logger.info(f"Page {page}: Found {len(jobs)} jobs, processed {len(processed_jobs)}, saved {saved}")
                    
                    # Check if we need to respect rate limits
                    if self.request_interval > 0 and page < max_pages:
                        await asyncio.sleep(self.request_interval)
                
                except (ScraperConnectionError, ScraperParsingError) as e:
                    self.logger.error(f"Error on page {page}: {str(e)}")
                    continue
                except Exception as e:
                    self.logger.error(f"Unexpected error on page {page}: {str(e)}")
                    # Don't fail the entire scrape for one page
                    continue
            
            # Update final status
            end_time = datetime.utcnow()
            self.status.update({
                "running": False,
                "status": "completed",
                "end_time": end_time.isoformat(),
                "progress": 100
            })
            
            # Update scraper run record
            session = get_session()
            try:
                scraper_run = session.query(ScraperRun).filter_by(run_id=self.run_id).first()
                if scraper_run:
                    scraper_run.end_time = end_time
                    scraper_run.status = "completed"
                    scraper_run.jobs_found = total_jobs
                    scraper_run.jobs_added = saved_jobs
                    session.commit()
            except Exception as e:
                self.logger.error(f"Error updating scraper run record: {str(e)}")
                session.rollback()
            finally:
                session.close()
            
            # Return results
            return {
                "success": True,
                "message": "Scraper completed successfully",
                "status": self.status,
                "total_jobs": total_jobs,
                "saved_jobs": saved_jobs
            }
        
        except Exception as e:
            # Handle any unhandled exceptions
            self.logger.error(f"Scraper failed with error: {str(e)}")
            
            # Update status
            end_time = datetime.utcnow()
            self.status.update({
                "running": False,
                "status": "error",
                "end_time": end_time.isoformat(),
                "error": str(e)
            })
            
            # Update scraper run record
            session = get_session()
            try:
                scraper_run = session.query(ScraperRun).filter_by(run_id=self.run_id).first()
                if scraper_run:
                    scraper_run.end_time = end_time
                    scraper_run.status = "error"
                    scraper_run.error_message = str(e)
                    session.commit()
            except Exception as db_error:
                self.logger.error(f"Error updating scraper run record: {str(db_error)}")
                session.rollback()
            finally:
                session.close()
            
            # Return error
            return {
                "success": False,
                "message": f"Scraper failed: {str(e)}",
                "status": self.status
            }
    
    def stop(self) -> Dict[str, Any]:
        """
        Stop a running scraper.
        
        Returns:
            Dictionary with operation result
        """
        if not self.status["running"]:
            return {
                "success": False,
                "message": "Scraper is not running",
                "status": self.status
            }
        
        # Update status
        self.status["running"] = False
        self.status["status"] = "stopping"
        
        return {
            "success": True,
            "message": "Scraper stop requested",
            "status": self.status
        }


class TooManyFailuresError(Exception):
    """Exception raised when too many consecutive failures occur."""
    pass
