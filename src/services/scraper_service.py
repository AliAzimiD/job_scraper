import os
import time
import json
import yaml
import random
from typing import Dict, Any, List, Optional, Tuple, Union
from datetime import datetime
from pathlib import Path
import threading
import asyncio
from concurrent.futures import ThreadPoolExecutor

import requests
from aiohttp import ClientSession, ClientTimeout, TCPConnector
import backoff

from ..models.job import Job
from .job_repository import JobRepository
from ..log_setup import get_logger
from ..config_manager import ConfigManager

# Get logger
logger = get_logger("scraper_service")

class ScraperService:
    """
    Service for scraping job postings with proper rate limiting and error handling.
    Can be run synchronously or asynchronously.
    """
    
    def __init__(
        self,
        config_path: Union[str, Path] = "config/api_config.yaml",
        job_repository: Optional[JobRepository] = None,
        max_concurrent_requests: int = 10,
        rate_limit_interval_ms: int = 200
    ):
        """
        Initialize the scraper service.
        
        Args:
            config_path: Path to API configuration file
            job_repository: Repository for job data
            max_concurrent_requests: Maximum number of concurrent API requests
            rate_limit_interval_ms: Interval between API requests in milliseconds
        """
        self.config_path = Path(config_path)
        self.job_repository = job_repository or JobRepository()
        self.max_concurrent_requests = max_concurrent_requests
        self.rate_limit_interval_ms = rate_limit_interval_ms
        
        # Load configuration
        self.config = self._load_config()
        
        # Initialize state
        self.is_running = False
        self.last_run = None
        self.total_jobs_found = 0
        self.new_jobs = 0
        self.status = "idle"
        self.error_message = None
    
    def _load_config(self) -> Dict[str, Any]:
        """
        Load API configuration from YAML file.
        
        Returns:
            Configuration dictionary
        """
        try:
            if not self.config_path.exists():
                raise FileNotFoundError(f"API config file not found at {self.config_path}")
                
            with open(self.config_path, 'r') as file:
                config = yaml.safe_load(file)
                
            return config
        except Exception as e:
            logger.error(f"Error loading API config: {e}")
            return {}
    
    def get_status(self) -> Dict[str, Any]:
        """
        Get the current scraper status.
        
        Returns:
            Status dictionary
        """
        return {
            "is_running": self.is_running,
            "last_run": self.last_run,
            "total_jobs_found": self.total_jobs_found,
            "new_jobs": self.new_jobs,
            "status": self.status,
            "error_message": self.error_message
        }
    
    def start_scrape(self, max_pages: int = 1) -> bool:
        """
        Start a synchronous scraping job in a separate thread.
        
        Args:
            max_pages: Maximum number of pages to scrape
            
        Returns:
            True if started successfully, False otherwise
        """
        if self.is_running:
            logger.warning("Scraper is already running")
            return False
        
        # Reset state
        self.is_running = True
        self.status = "running"
        self.last_run = datetime.now().isoformat()
        self.total_jobs_found = 0
        self.new_jobs = 0
        self.error_message = None
        
        # Start scraper in a separate thread
        thread = threading.Thread(
            target=self._run_scraper_thread,
            args=(max_pages,)
        )
        thread.daemon = True
        thread.start()
        
        logger.info(f"Started scraper with max_pages={max_pages}")
        return True
    
    def _run_scraper_thread(self, max_pages: int) -> None:
        """
        Run the scraper in a separate thread.
        
        Args:
            max_pages: Maximum number of pages to scrape
        """
        try:
            # Get API configuration
            api_config = self.config.get('api', {})
            request_config = self.config.get('request', {})
            
            base_url = api_config.get('base_url')
            headers = api_config.get('headers', {})
            default_payload = request_config.get('default_payload', {})
            
            if not base_url:
                raise ValueError("API base URL not found in configuration")
                
            logger.info(f"Using API URL: {base_url}")
            
            # Initialize tracking variables
            total_jobs = 0
            new_jobs = 0
            
            # Process pages
            for page in range(1, max_pages + 1):
                if not self.is_running:
                    logger.info("Scraper was stopped")
                    break
                    
                logger.info(f"Processing page {page}/{max_pages}")
                
                # Create payload for this page
                payload = dict(default_payload)
                payload['page'] = page
                
                try:
                    # Make API request with backoff for retries
                    response = self._make_api_request_with_retry(
                        base_url=base_url,
                        headers=headers,
                        payload=payload
                    )
                    
                    # Parse response
                    jobs = response.get('data', {}).get('jobPosts', [])
                    
                    if not jobs:
                        logger.warning(f"No jobs found on page {page}")
                        continue
                        
                    logger.info(f"Found {len(jobs)} jobs on page {page}")
                    total_jobs += len(jobs)
                    
                    # Process jobs
                    jobs_to_upsert = []
                    for job_data in jobs:
                        try:
                            # Convert API data to Job object
                            job = Job.from_api_data(job_data)
                            jobs_to_upsert.append(job)
                        except Exception as e:
                            logger.error(f"Error processing job {job_data.get('id')}: {e}")
                            continue
                    
                    # Bulk upsert jobs
                    if jobs_to_upsert:
                        inserted, updated = self.job_repository.bulk_upsert_jobs(jobs_to_upsert)
                        new_jobs += inserted
                        logger.info(f"Upserted {len(jobs_to_upsert)} jobs: {inserted} new, {updated} updated")
                    
                    # Sleep to avoid rate limiting (if not last page)
                    if page < max_pages:
                        time.sleep(self.rate_limit_interval_ms / 1000)
                        
                except Exception as e:
                    logger.error(f"Error processing page {page}: {e}")
                    continue
                    
            # Update state after scraping
            self.total_jobs_found = total_jobs
            self.new_jobs = new_jobs
            self.status = "completed"
            logger.info(f"Scraping completed: {total_jobs} total jobs, {new_jobs} new jobs")
            
        except Exception as e:
            logger.error(f"Error running scraper: {e}")
            self.status = "error"
            self.error_message = str(e)
        finally:
            self.is_running = False
    
    @backoff.on_exception(
        backoff.expo,
        (requests.exceptions.RequestException, requests.exceptions.Timeout),
        max_tries=3,
        jitter=backoff.full_jitter
    )
    def _make_api_request_with_retry(
        self,
        base_url: str,
        headers: Dict[str, str],
        payload: Dict[str, Any]
    ) -> Dict[str, Any]:
        """
        Make an API request with exponential backoff for retries.
        
        Args:
            base_url: API URL
            headers: Request headers
            payload: Request payload
            
        Returns:
            API response data
        """
        response = requests.post(
            base_url,
            headers=headers,
            json=payload,
            timeout=30
        )
        response.raise_for_status()
        return response.json()
    
    async def start_scrape_async(self, max_pages: int = 1) -> bool:
        """
        Start an asynchronous scraping job.
        
        Args:
            max_pages: Maximum number of pages to scrape
            
        Returns:
            True if started successfully, False otherwise
        """
        if self.is_running:
            logger.warning("Scraper is already running")
            return False
            
        # Reset state
        self.is_running = True
        self.status = "running"
        self.last_run = datetime.now().isoformat()
        self.total_jobs_found = 0
        self.new_jobs = 0
        self.error_message = None
        
        # Start async task
        asyncio.create_task(self._run_scraper_async(max_pages))
        
        logger.info(f"Started async scraper with max_pages={max_pages}")
        return True
    
    async def _run_scraper_async(self, max_pages: int) -> None:
        """
        Run the scraper asynchronously.
        
        Args:
            max_pages: Maximum number of pages to scrape
        """
        try:
            # Get API configuration
            api_config = self.config.get('api', {})
            request_config = self.config.get('request', {})
            
            base_url = api_config.get('base_url')
            headers = api_config.get('headers', {})
            default_payload = request_config.get('default_payload', {})
            
            if not base_url:
                raise ValueError("API base URL not found in configuration")
                
            logger.info(f"Using API URL: {base_url}")
            
            # Initialize tracking variables
            total_jobs = 0
            new_jobs = 0
            
            # Process pages in batches with rate limiting
            semaphore = asyncio.Semaphore(self.max_concurrent_requests)
            
            # Create tasks for each page
            tasks = []
            for page in range(1, max_pages + 1):
                # Create payload for this page
                payload = dict(default_payload)
                payload['page'] = page
                
                # Create a task for this page
                task = asyncio.create_task(
                    self._process_page_async(
                        page=page,
                        max_pages=max_pages,
                        base_url=base_url,
                        headers=headers,
                        payload=payload,
                        semaphore=semaphore
                    )
                )
                tasks.append(task)
            
            # Wait for all tasks to complete
            results = await asyncio.gather(*tasks, return_exceptions=True)
            
            # Process results
            for result in results:
                if isinstance(result, Exception):
                    logger.error(f"Error in page processing task: {result}")
                    continue
                    
                page_jobs, page_new_jobs = result
                total_jobs += page_jobs
                new_jobs += page_new_jobs
            
            # Update state after scraping
            self.total_jobs_found = total_jobs
            self.new_jobs = new_jobs
            self.status = "completed"
            logger.info(f"Async scraping completed: {total_jobs} total jobs, {new_jobs} new jobs")
            
        except Exception as e:
            logger.error(f"Error running async scraper: {e}")
            self.status = "error"
            self.error_message = str(e)
        finally:
            self.is_running = False
    
    async def _process_page_async(
        self,
        page: int,
        max_pages: int,
        base_url: str,
        headers: Dict[str, str],
        payload: Dict[str, Any],
        semaphore: asyncio.Semaphore
    ) -> Tuple[int, int]:
        """
        Process a single page of job listings asynchronously.
        
        Args:
            page: Page number
            max_pages: Maximum number of pages
            base_url: API URL
            headers: Request headers
            payload: Request payload
            semaphore: Semaphore for limiting concurrent requests
            
        Returns:
            Tuple of (jobs_count, new_jobs_count)
        """
        if not self.is_running:
            return (0, 0)
            
        logger.info(f"Processing page {page}/{max_pages}")
        
        # Use semaphore to limit concurrency
        async with semaphore:
            try:
                # Add delay for rate limiting
                await asyncio.sleep(self.rate_limit_interval_ms / 1000)
                
                # Make API request
                async with ClientSession(
                    timeout=ClientTimeout(total=30),
                    connector=TCPConnector(ssl=False)
                ) as session:
                    # Make API request with retry
                    response_data = await self._make_api_request_async_with_retry(
                        session=session,
                        url=base_url,
                        headers=headers,
                        payload=payload
                    )
                    
                    # Parse response
                    jobs = response_data.get('data', {}).get('jobPosts', [])
                    
                    if not jobs:
                        logger.warning(f"No jobs found on page {page}")
                        return (0, 0)
                    
                    logger.info(f"Found {len(jobs)} jobs on page {page}")
                    
                    # Process jobs in a thread pool to avoid blocking the event loop
                    loop = asyncio.get_event_loop()
                    with ThreadPoolExecutor() as executor:
                        inserted, updated = await loop.run_in_executor(
                            executor,
                            self._process_jobs_batch,
                            jobs
                        )
                    
                    logger.info(f"Page {page}: Processed {len(jobs)} jobs, {inserted} new, {updated} updated")
                    return (len(jobs), inserted)
                    
            except Exception as e:
                logger.error(f"Error processing page {page}: {e}")
                return (0, 0)
    
    def _process_jobs_batch(self, jobs_data: List[Dict[str, Any]]) -> Tuple[int, int]:
        """
        Process a batch of jobs from API data. Used for thread pool execution.
        
        Args:
            jobs_data: List of job data dictionaries from API
            
        Returns:
            Tuple of (inserted_count, updated_count)
        """
        try:
            # Convert API data to Job objects
            jobs_to_upsert = []
            for job_data in jobs_data:
                try:
                    job = Job.from_api_data(job_data)
                    jobs_to_upsert.append(job)
                except Exception as e:
                    logger.error(f"Error processing job {job_data.get('id')}: {e}")
                    continue
            
            # Bulk upsert jobs
            if jobs_to_upsert:
                return self.job_repository.bulk_upsert_jobs(jobs_to_upsert)
            else:
                return (0, 0)
                
        except Exception as e:
            logger.error(f"Error processing jobs batch: {e}")
            return (0, 0)
    
    async def _make_api_request_async_with_retry(
        self,
        session: ClientSession,
        url: str,
        headers: Dict[str, str],
        payload: Dict[str, Any],
        max_retries: int = 3
    ) -> Dict[str, Any]:
        """
        Make an async API request with retries.
        
        Args:
            session: aiohttp ClientSession
            url: API URL
            headers: Request headers
            payload: Request payload
            max_retries: Maximum number of retries
            
        Returns:
            API response data
        """
        retries = 0
        while retries < max_retries:
            try:
                async with session.post(url, headers=headers, json=payload) as response:
                    response.raise_for_status()
                    return await response.json()
            except Exception as e:
                retries += 1
                if retries >= max_retries:
                    logger.error(f"API request failed after {max_retries} attempts: {e}")
                    raise
                    
                # Exponential backoff with jitter
                wait_time = (2 ** retries) + (0.1 * random.randint(0, 1000)) / 1000
                logger.warning(f"API request failed, retrying in {wait_time:.2f}s: {e}")
                await asyncio.sleep(wait_time) 