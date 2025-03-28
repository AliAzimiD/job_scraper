import aiohttp
import asyncio
import json
import traceback
import uuid
from datetime import datetime, timedelta
from pathlib import Path
from typing import Dict, List, Optional, Union, Any, AsyncGenerator
import time
import dateparser
import hashlib
import os
import random

import pandas as pd
from tenacity import retry, stop_after_attempt, wait_exponential
import asyncpg

from .config_manager import ConfigManager
from .db_manager import DatabaseManager
from .log_setup import get_logger


class JobScraper:
    """
    Asynchronous job scraper that fetches job listings from a specified API,
    processes them, and optionally stores them in a database or local disk.
    Uses streaming pattern for memory efficiency with large datasets.
    """

    def __init__(
        self,
        config_path: str = "config/api_config.yaml",
        save_dir: str = "job_data",
        db_manager: Optional[DatabaseManager] = None,
    ) -> None:
        """
        Initialize the JobScraper with configuration, logging, and optional DB.

        Args:
            config_path (str): Path to the YAML config file.
            save_dir (str): Directory to store data and logs (only used if saving locally).
            db_manager (Optional[DatabaseManager]): If provided, use this manager for DB operations.
        """
        self.logger = get_logger("JobScraper")

        # Load configuration (YAML + environment overrides)
        self.config_manager = ConfigManager(config_path)
        self.api_config: Dict[str, Any] = self.config_manager.api_config
        self.request_config: Dict[str, Any] = self.config_manager.request_config
        self.scraper_config: Dict[str, Any] = self.config_manager.scraper_config

        # Setup directories (if local saving is needed)
        self.save_dir = Path(save_dir)
        self.save_dir.mkdir(parents=True, exist_ok=True)
        self.raw_dir = self.save_dir / "raw_data"
        self.processed_dir = self.save_dir / "processed_data"
        self.log_dir = self.save_dir / "logs"
        for d in [self.raw_dir, self.processed_dir, self.log_dir]:
            d.mkdir(parents=True, exist_ok=True)

        # Database usage config
        database_cfg = self.scraper_config.get("database", {})
        self.db_enabled = database_cfg.get("enabled", False)
        self.db_manager = db_manager
        if self.db_enabled and not self.db_manager:
            # If the database is enabled but no db_manager was passed, create one
            self.logger.info("Database integration enabled but no manager provided; creating one.")
            db_config = self.config_manager.database_config
            self.db_manager = DatabaseManager(
                connection_string=db_config.get("connection_string"),
                schema=db_config.get("schema", "public"),
                batch_size=db_config.get("batch_size", 1000),
            )

        # API base URL + request headers
        self.base_url: str = self.api_config["base_url"]
        self.headers: Dict[str, str] = self.api_config["headers"]

        # Tracking counters
        self.current_batch: int = 0
        self.total_jobs_scraped: int = 0
        self.failed_requests: List[int] = []

        # Concurrency limit for HTTP requests
        max_concurrent = self.scraper_config.get("max_concurrent_requests", 3)
        self.semaphore = asyncio.Semaphore(max_concurrent)
        
        # Stream processing queue
        self.processing_queue = asyncio.Queue(maxsize=self.scraper_config.get("queue_size", 1000))
        
        # Rate limiting
        self.rate_limit = self.scraper_config.get("rate_limit", {})
        self.request_interval = self.rate_limit.get("request_interval_ms", 0) / 1000
        
        # Initialize monitoring data
        self.monitoring_data = {
            "start_time": datetime.now().isoformat(),
            "phases": {
                "initialization": {"status": "pending", "time": 0},
                "scraping": {"status": "pending", "time": 0},
                "cleanup": {"status": "pending", "time": 0}
            },
            "jobs_processed": 0,
            "batches_processed": 0,
            "errors": []
        }
        
        # Set source name for jobs
        self.source_name = self.api_config.get("source_name", "api_scraper")

        self.logger.info(
            "JobScraper initialized successfully. Database Enabled? "
            f"{self.db_enabled}"
        )

    async def initialize(self) -> bool:
        """
        Initialize the scraper, including DB connections if enabled.

        Returns:
            bool: True if initialization was successful, False otherwise.
        """
        try:
            if self.db_enabled and self.db_manager:
                self.logger.info("Initializing database connection (JobScraper)...")
                success = await self.db_manager.initialize()
                if not success:
                    # If DB fails, we fallback to local file saving
                    self.logger.warning("DB initialization failed, falling back to file storage.")
                    self.db_enabled = False
            return True
        except Exception as e:
            self.logger.error(f"Error during scraper initialization: {str(e)}")
            return False

    def create_payload(self, page: int = 1) -> Dict[str, Any]:
        """
        Create the request payload for a given page using the default request config.

        Args:
            page (int): Page number to fetch.

        Returns:
            Dict[str, Any]: JSON body for the POST request.
        """
        payload = dict(self.request_config.get("default_payload", {}))
        payload.update(
            {
                "page": page,
                "pageSize": self.scraper_config.get("batch_size", 100),
                "nextPageToken": None,
            }
        )
        return payload

    @retry(
        stop=stop_after_attempt(3), 
        wait=wait_exponential(multiplier=1, min=4, max=10),
        retry=lambda retry_state: isinstance(retry_state.outcome.exception(), 
            (aiohttp.ClientError, asyncio.TimeoutError, json.JSONDecodeError))
    )
    async def fetch_jobs(
        self,
        session: aiohttp.ClientSession,
        json_body: Dict[str, Any],
        page: int
    ) -> Optional[Dict[str, Any]]:
        """
        Fetch jobs from the API with retry logic using tenacity.

        Args:
            session (aiohttp.ClientSession): Shared session for HTTP requests.
            json_body (Dict[str, Any]): POST body JSON for the request.
            page (int): The page number being fetched.

        Returns:
            Optional[Dict[str, Any]]: Parsed JSON data if successful, else None.
        """
        try:
            self.logger.info(f"Fetching page {page} from {self.base_url}")
        async with self.semaphore:
                try:
                    start_time = time.time()
                    # Get timeout from config or use default
                    timeout = aiohttp.ClientTimeout(
                        total=self.scraper_config.get("timeout", 60),
                        connect=self.scraper_config.get("connect_timeout", 20)
                    )
                    
            async with session.post(
                self.base_url,
                headers=self.headers,
                json=json_body,
                        timeout=timeout,
            ) as response:
                        elapsed = time.time() - start_time
                        self.logger.debug(f"Request to page {page} took {elapsed:.2f}s")
                        
                        # Check HTTP status code
                        if response.status >= 400:
                            error_text = await response.text()
                            self.logger.error(
                                f"HTTP error {response.status} on page {page}: {error_text[:200]}"
                            )
                            
                            # Specific handling for common error codes
                            if response.status == 429:
                                self.logger.warning("Rate limit exceeded, backing off")
                                # Add random jitter to base delay (0.5-1.5x original delay)
                                jitter = 0.5 + random.random()
                                retry_after = response.headers.get("Retry-After", "60")
                                try:
                                    delay = float(retry_after) * jitter
                                except ValueError:
                                    delay = 60 * jitter
                                await asyncio.sleep(delay)
                            elif response.status in (502, 503, 504):
                                self.logger.warning(f"Server error ({response.status}), temporary issue")
                            elif response.status == 401:
                                self.logger.error("Authentication failed. Check API credentials.")
                                # Don't retry auth failures
                                return None
                                
                            response.raise_for_status()  # This will trigger the retry
                        
                        # Try to parse JSON response
                        try:
                data = await response.json()
                            
                            # Validate basic structure of the response
                            if not isinstance(data, dict):
                                self.logger.warning(f"Response not a dictionary on page {page}")
                                return None
                                
                            if 'data' not in data:
                                # Check for error response structure
                                if 'error' in data:
                                    self.logger.error(f"API returned error: {data['error']}")
                                    if data.get('status', 200) >= 400:
                                        # This is an error worth retrying 
                                        raise aiohttp.ClientResponseError(
                                            request_info=response.request_info,
                                            history=response.history,
                                            status=data.get('status', 500),
                                            message=str(data.get('error')),
                                            headers=response.headers
                                        )
                                self.logger.warning(f"Invalid response format on page {page}")
                                return None
                                
                            # Check for job posts 
                            jobs_data = data.get('data', {})
                            
                            # Extract job posts if available, with different field names
                            job_posts = None
                            for field in ['jobPosts', 'jobs', 'items', 'results']:
                                if field in jobs_data:
                                    job_posts = jobs_data[field]
                                    break
                            
                            # If no job posts found with any field name, return None
                            if job_posts is None:
                                self.logger.warning(f"No recognized job data found on page {page}")
                                return None
                            
                            jobs_count = len(job_posts)
                            self.logger.info(f"Successfully fetched page {page} with {jobs_count} jobs")
                            
                            if jobs_count == 0:
                                self.logger.warning(f"No jobs found on page {page}")
                                
                return data
                        except json.JSONDecodeError as e:
                            self.logger.error(f"JSON parsing error on page {page}: {str(e)}")
                            # Get first part of the response text for debugging
                            text = await response.text()
                            self.logger.error(f"Response text (first 200 chars): {text[:200]}")
                            raise
                
                except asyncio.TimeoutError:
                    self.logger.error(f"Timeout fetching page {page}")
                    raise
                except aiohttp.ClientError as e:
                    self.logger.error(f"HTTP client error on page {page}: {str(e)}")
                    raise
                except json.JSONDecodeError as e:
                    self.logger.error(f"JSON parsing error: {str(e)}")
                    raise
        except Exception as e:
            self.logger.error(f"Unexpected error fetching page {page}: {str(e)}")
            self.logger.error(traceback.format_exc())
            
            # Save error details for analysis
            try:
                error_file = self.log_dir / f"fetch_error_page_{page}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt"
                with open(error_file, "w") as f:
                    f.write(f"Error fetching page {page}: {str(e)}\n")
                    f.write(f"Exception type: {type(e).__name__}\n")
                    f.write(f"Traceback:\n{traceback.format_exc()}")
                    f.write(f"Request payload:\n{json.dumps(json_body, indent=2)}")
                self.logger.info(f"Saved fetch error details to {error_file}")
            except Exception:
                pass  # Don't let error logging errors cascade
                
            raise

    async def process_jobs(self, jobs: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Validate each job before insertion. Apply enhanced data validation and cleaning.
        Normalize data fields and filter out invalid entries.

        Args:
            jobs (List[Dict[str, Any]]): Raw job data from the API.

        Returns:
            List[Dict[str, Any]]: Filtered/validated job objects.
        """
        processed = []
        duplicates = 0
        invalid = 0
        
        # Track seen job IDs for deduplication
        seen_ids = set()
        
        for job in jobs:
            try:
                # Skip jobs with missing required fields
                if not all(k in job for k in ("id", "title", "activationTime")):
                    self.logger.warning(
                        f"Skipping invalid job: {job.get('id', 'unknown')} - missing required fields"
                    )
                    invalid += 1
                    continue
                
                # Deduplicate based on ID
                job_id = job.get('id')
                if job_id in seen_ids:
                    duplicates += 1
                    continue
                seen_ids.add(job_id)
                
                # Data cleaning/normalization
                cleaned_job = self._clean_job_data(job)
                
                # Additional validation checks
                if not self._validate_job(cleaned_job):
                    invalid += 1
                    continue
                    
                processed.append(cleaned_job)
            except Exception as e:
                self.logger.error(f"Error processing job: {str(e)}")
                invalid += 1
                continue
                
        self.logger.info(f"Processed {len(jobs)} jobs: {len(processed)} valid, {duplicates} duplicates, {invalid} invalid")
        return processed
        
    def _clean_job_data(self, job: Dict[str, Any]) -> Dict[str, Any]:
        """
        Clean and normalize job data fields.
        
        Args:
            job (Dict[str, Any]): Raw job data
            
        Returns:
            Dict[str, Any]: Cleaned job data
        """
        cleaned = job.copy()
        
        # Clean text fields - strip whitespace, handle None values
        text_fields = ["title", "company_name_fa", "company_name_en", "province_match_city"]
        for field in text_fields:
            if field in cleaned and cleaned[field]:
                if isinstance(cleaned[field], str):
                    cleaned[field] = cleaned[field].strip()
                elif cleaned[field] is not None:
                    # Convert non-string values to strings
                    cleaned[field] = str(cleaned[field]).strip()
        
        # Normalize date fields - ensure proper format
        if "activationTime" in cleaned and cleaned["activationTime"]:
            try:
                # Convert to proper datetime if it's not already
                if isinstance(cleaned["activationTime"], str):
                    # Handle different date formats
                    formats = [
                        "%Y-%m-%dT%H:%M:%S.%fZ",  # ISO format with microseconds
                        "%Y-%m-%dT%H:%M:%SZ",     # ISO format without microseconds
                        "%Y-%m-%d %H:%M:%S",      # Standard datetime
                        "%Y-%m-%d"                # Date only
                    ]
                    
                    for fmt in formats:
                        try:
                            dt = datetime.strptime(cleaned["activationTime"], fmt)
                            cleaned["activationTime"] = dt.isoformat()
                            break
                        except ValueError:
                            continue
            except Exception as e:
                self.logger.warning(f"Failed to normalize date: {cleaned['activationTime']}, error: {str(e)}")
        
        # Ensure locations is a list
        if "locations" in cleaned:
            if cleaned["locations"] is None:
                cleaned["locations"] = []
            elif isinstance(cleaned["locations"], str):
                # Try to parse JSON string
                try:
                    cleaned["locations"] = json.loads(cleaned["locations"])
                except json.JSONDecodeError:
                    cleaned["locations"] = [cleaned["locations"]]
            elif not isinstance(cleaned["locations"], list):
                cleaned["locations"] = [cleaned["locations"]]
        
        # Normalize salary data for consistency
        if "salary" in cleaned and cleaned["salary"]:
            salary_data = cleaned["salary"]
            
            # If it's a string, try to convert to object
            if isinstance(salary_data, str):
                try:
                    salary_data = json.loads(salary_data)
                except json.JSONDecodeError:
                    salary_data = {"raw": salary_data}
                    
            # Ensure salary has a standard structure
            if isinstance(salary_data, dict):
                # Extract min/max if possible
                if "min" in salary_data and salary_data["min"]:
                    try:
                        cleaned["normalize_salary_min"] = float(salary_data["min"])
                    except (ValueError, TypeError):
                        pass
                        
                if "max" in salary_data and salary_data["max"]:
                    try:
                        cleaned["normalize_salary_max"] = float(salary_data["max"])
                    except (ValueError, TypeError):
                        pass
            
            cleaned["salary"] = salary_data
            
        return cleaned
        
    def _validate_job(self, job: Dict[str, Any]) -> bool:
        """
        Validate a job dictionary to ensure it has required fields.
        
        Args:
            job: Job dictionary to validate.
            
        Returns:
            bool: True if valid, False otherwise.
        """
        # Required fields validation
        required_fields = ["title", "url", "locations"]
        
        # Check for all required fields
        for field in required_fields:
            if field not in job or job[field] is None:
                self.logger.warning(f"Job missing required field: {field}")
            return False
            
            # String type fields should have content
            if field in ["title", "url"] and (not isinstance(job[field], str) or not job[field].strip()):
                self.logger.warning(f"Job has empty {field}: {job.get('id', 'unknown_id')}")
                return False
        
        # Check that locations is either a list or string
        if "locations" in job:
            if not (isinstance(job["locations"], list) or isinstance(job["locations"], str)):
                self.logger.warning(f"Job locations is not a list or string: {job.get('id', 'unknown_id')}")
                return False
            
            # If it's a list, ensure it's not empty
            if isinstance(job["locations"], list) and not job["locations"]:
                self.logger.warning(f"Job has empty locations list: {job.get('id', 'unknown_id')}")
                return False
        
        # Activation time validation
        if "activationTime" in job and job["activationTime"]:
            try:
                # Ensure activation time can be parsed as a date string
                if isinstance(job["activationTime"], str):
                    # Attempt to parse the date to confirm it's valid
                    dt = dateparser.parse(job["activationTime"])
                    if dt is None:
                        self.logger.warning(f"Job has unparseable activationTime: {job.get('activationTime')}")
                        # Instead of failing, we'll set a reasonable default (now)
                        job["activationTime"] = datetime.now().isoformat()
            except Exception as e:
                self.logger.warning(f"Error parsing activationTime: {str(e)}")
                # Set a reasonable default instead of failing
                job["activationTime"] = datetime.now().isoformat()
        
        # Check URL format
        if "url" in job and isinstance(job["url"], str):
            if not job["url"].startswith(("http://", "https://")):
                self.logger.warning(f"Job has invalid URL format: {job['url']}")
                # Attempt to fix by adding https://
                if not job["url"].startswith("//"):
                    job["url"] = f"https://{job['url']}"
                else:
                    job["url"] = f"https:{job['url']}"

        # Salary field validation and normalization
        if "salary" in job:
            salary = job["salary"]
            
            # If salary is None or empty, set it to empty string
            if salary is None or (isinstance(salary, str) and not salary.strip()):
                job["salary"] = ""
            
            # If salary is a dictionary, ensure it has expected keys
            if isinstance(salary, dict) and not any(k in salary for k in ["min", "max", "text"]):
                # Convert to string representation
                try:
                    job["salary"] = json.dumps(salary, ensure_ascii=False)
            except Exception:
                    job["salary"] = str(salary)
            
            # If salary is a list, convert to string
            if isinstance(salary, list):
                try:
                    job["salary"] = json.dumps(salary, ensure_ascii=False)
                except Exception:
                    job["salary"] = str(salary)
                
        # Description validation
        if "description" in job and job["description"] is not None:
            # Ensure description is a string
            if not isinstance(job["description"], str):
                try:
                    job["description"] = str(job["description"])
                except Exception:
                    job["description"] = ""
                    
            # Truncate excessively long descriptions
            max_description_length = 65535  # Typical TEXT field limit in many DBs
            if len(job["description"]) > max_description_length:
                job["description"] = job["description"][:max_description_length]
                self.logger.warning(f"Truncated very long description for job: {job.get('id', 'unknown_id')}")

        # Add job source if missing
        if "source" not in job or not job["source"]:
            # Check if source_name exists in the class, add a default if not
            if hasattr(self, 'source_name'):
                job["source"] = self.source_name
            else:
                job["source"] = "api_scraper"
            
        # Generate ID if missing
        if "id" not in job or not job["id"]:
            # Create a stable ID based on title and URL
            id_base = f"{job.get('title', '')}-{job.get('url', '')}"
            job["id"] = hashlib.md5(id_base.encode()).hexdigest()
            self.logger.debug(f"Generated id for job: {job['id']}")
            
        return True

    async def _process_jobs(self, jobs: List[Dict[str, Any]]) -> int:
        """
        Insert or upsert job data into the DB if enabled, otherwise save them to file if configured.

        Args:
            jobs (List[Dict[str, Any]]): Valid job dictionaries to store.

        Returns:
            int: Number of jobs successfully processed (upserted or saved).
        """
        if not jobs:
            return 0

        processed_count = 0
            batch_id = str(uuid.uuid4())
        start_time = time.time()
        
        # New: Circuit breaker pattern variables
        db_circuit_open = False  # If True, skip DB operations completely
        consecutive_db_failures = 0
        max_consecutive_failures = self.scraper_config.get("db_circuit_breaker_threshold", 5)
        
        try:
            # If DB enabled, attempt saving to DB
            if self.db_enabled and self.db_manager and not db_circuit_open:
                # Pre-check if DB is connected before attempting insert
                if not self.db_manager.is_connected:
                    self.logger.warning("Database not connected. Attempting to reconnect...")
                    reconnected = await self.db_manager.ensure_connection()
                    if not reconnected:
                        self.logger.error("Failed to reconnect to database, falling back to file storage")
                        # Track connection failure
                        consecutive_db_failures += 1
                    else:
                        self.logger.info("Successfully reconnected to database")
                
                # Only proceed with DB insert if we have a connection
                if self.db_manager.is_connected:
                    try:
                self.logger.info(f"Saving {len(jobs)} jobs to DB in batch_id={batch_id}")
                        # Try database insertion with retry logic
                        retries = 0
                        max_retries = self.scraper_config.get("db_retries", 3)
                        initial_backoff = self.scraper_config.get("retry_initial_delay", 1.0)
                        backoff_factor = self.scraper_config.get("retry_backoff_factor", 2)
                        
                        while retries <= max_retries:
                            try:
                inserted_count = await self.db_manager.insert_jobs(jobs, batch_id)
                self.logger.info(
                    f"DB upsert complete: {inserted_count} jobs inserted/updated for batch {batch_id}"
                )
                                processed_count = inserted_count
                                
                                # Reset failure counter on success
                                consecutive_db_failures = 0

                # If database saving was successful, skip file saving if config demands
                if inserted_count > 0 and not self.config_manager.should_save_files_with_db():
                    self.logger.info("All jobs saved to DB; skipping file-based storage.")
                    return inserted_count

                                # Break out of retry loop on success
                                break
                                
                            except asyncpg.exceptions.PostgresConnectionError as conn_error:
                                retries += 1
                                consecutive_db_failures += 1
                                
                                # Log specific connection error for troubleshooting
                                self.logger.error(f"Database connection error: {str(conn_error)}")
                                
                                if retries > max_retries:
                                    self.logger.error(f"Failed to connect to database after {max_retries} attempts")
                                    # Check if we need to open the circuit breaker
                                    if consecutive_db_failures >= max_consecutive_failures:
                                        self.logger.critical(
                                            f"Opening circuit breaker after {consecutive_db_failures} consecutive failures. "
                                            "Switching to file-only mode."
                                        )
                                        db_circuit_open = True
                                    raise  # Re-raise to be caught by outer try/except
                                
                                wait_time = initial_backoff * (backoff_factor ** (retries - 1))
                                self.logger.warning(
                                    f"Connection error (attempt {retries}/{max_retries}), retrying in {wait_time:.2f}s"
                                )
                                await asyncio.sleep(wait_time)
                                
                            except Exception as db_error:
                                retries += 1
                                if retries > max_retries:
                                    self.logger.error(f"Failed to save to database after {max_retries} attempts")
                                    raise db_error  # Re-raise to be caught by outer try/except
                                
                                wait_time = initial_backoff * (backoff_factor ** (retries - 1))
                                self.logger.warning(
                                    f"Database error (attempt {retries}/{max_retries}), retrying in {wait_time:.2f}s: {str(db_error)}"
                                )
                                await asyncio.sleep(wait_time)
                    
                    except Exception as db_error:
                        self.logger.error(f"Database insertion error: {str(db_error)}")
                        self.logger.error(traceback.format_exc())
                        # Fall through to file storage as backup

            # Save to file if DB saving failed or if DB is not enabled or circuit breaker is open
            try:
                file_save_start = time.time()
                self.logger.info(f"Saving {len(jobs)} jobs to file (batch {self.current_batch})")
            self.save_batch(jobs, self.current_batch)
                file_save_time = time.time() - file_save_start
                self.logger.debug(f"Saved jobs to file in {file_save_time:.2f}s")
                
                if processed_count == 0:  # If DB insert didn't work or wasn't attempted
                    processed_count = len(jobs)
                    
            self.current_batch += 1
                    
            except Exception as file_error:
                self.logger.error(f"Error saving to file: {str(file_error)}")
                self.logger.error(traceback.format_exc())
                # If we also failed to save to file and had no DB success, we have a problem
                if processed_count == 0:
                    raise  # Re-raise to be caught by outer try/except

            # Log performance metrics
            elapsed = time.time() - start_time
            jobs_per_second = processed_count / elapsed if elapsed > 0 else 0
            self.logger.info(
                f"Processed {processed_count} jobs in {elapsed:.2f}s "
                f"({jobs_per_second:.1f} jobs/s)"
            )
            
            # Log memory usage periodically
            if self.current_batch % 10 == 0:
                try:
                    import psutil
                    process = psutil.Process(os.getpid())
                    memory_mb = process.memory_info().rss / 1024 / 1024
                    self.logger.info(f"Current memory usage: {memory_mb:.1f} MB")
                except ImportError:
                    pass  # psutil not available, skip memory logging
                except Exception as mem_error:
                    self.logger.debug(f"Error logging memory usage: {str(mem_error)}")
            
            return processed_count
            
        except Exception as e:
            self.logger.error(f"Critical error in _process_jobs: {str(e)}")
            self.logger.error(traceback.format_exc())
            
            # Log detailed error information
            error_info = {
                "batch_id": batch_id,
                "job_count": len(jobs),
                "error": str(e),
                "error_type": type(e).__name__,
                "timestamp": datetime.now().isoformat(),
                "db_circuit_open": db_circuit_open,
                "consecutive_db_failures": consecutive_db_failures
            }
            
            # Save error details to a file
            try:
                error_file = self.log_dir / f"processing_error_{batch_id}.json"
                with open(error_file, "w") as f:
                    json.dump(error_info, f, indent=2, default=str)
                self.logger.info(f"Saved error details to {error_file}")
            except Exception:
                pass  # Don't let error logging errors cascade
                
            # Try to save a sample of the failing jobs for debugging
            try:
                sample_size = min(5, len(jobs))
                sample_jobs = jobs[:sample_size]
                
                # Remove potentially large fields
                for job in sample_jobs:
                    if "description" in job and isinstance(job["description"], str) and len(job["description"]) > 100:
                        job["description"] = job["description"][:100] + "..."
                
                sample_file = self.log_dir / f"job_sample_{batch_id}.json"
                with open(sample_file, "w") as f:
                    json.dump(sample_jobs, f, indent=2, default=str)
                self.logger.info(f"Saved sample of {sample_size} problematic jobs to {sample_file}")
            except Exception:
                pass  # Don't let sample saving errors cascade
            
            # Attempt emergency file save if all else failed and no jobs were processed
            if processed_count == 0:
                try:
                    emergency_file = self.raw_dir / f"emergency_jobs_{batch_id}.json"
                    with open(emergency_file, "w") as f:
                        # Save jobs with minimal processing
                        json.dump([{k: v for k, v in job.items() if not isinstance(v, (dict, list)) or k == 'id'}
                                 for job in jobs], f, default=str)
                    self.logger.info(f"Emergency save: Dumped {len(jobs)} jobs to {emergency_file}")
                except Exception as save_error:
                    self.logger.error(f"Emergency save failed: {str(save_error)}")
                
            return 0  # Return 0 to indicate no jobs were processed

    def save_batch(self, jobs: List[Dict[str, Any]], batch_number: int) -> None:
        """
        Optionally save a batch of jobs to JSON, Parquet, and CSV files.
        Only used if config_manager.should_save_files_with_db() is True or DB is disabled.

        Args:
            jobs (List[Dict[str, Any]]): List of job items to save.
            batch_number (int): Index of the current batch.
        """
        if not jobs:
            return

        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        batch_name = f"batch_{batch_number:04d}_{timestamp}"
        file_save_success = False

        try:
            # Create a temporary directory for atomic file operations
            temp_dir = self.save_dir / "temp"
            temp_dir.mkdir(exist_ok=True)
            
            # Save to JSON (always)
            json_temp = temp_dir / f"{batch_name}.json.tmp"
            json_path = self.raw_dir / f"{batch_name}.json"
            
            try:
                with open(json_temp, "w", encoding="utf-8") as f:
                    json.dump(jobs, f, ensure_ascii=False, indent=2, default=str)
                # Move file atomically to avoid partial writes
                json_temp.rename(json_path)
                file_save_success = True
                self.logger.debug(f"Saved JSON data to {json_path}")
            except Exception as e:
                self.logger.error(f"Error saving JSON: {str(e)}")
                
            # Only proceed with other formats if JSON was successful
            if file_save_success:
                try:
                    # Normalize the data for pandas
                    normalized_jobs = []
                    for job in jobs:
                        # Create a flattened copy of the job for DataFrame conversion
                        normalized_job = {}
                        for k, v in job.items():
                            # Handle nested structures that might cause issues
                            if isinstance(v, (dict, list)):
                                normalized_job[k] = json.dumps(v, ensure_ascii=False, default=str)
                            else:
                                normalized_job[k] = v
                        normalized_jobs.append(normalized_job)
                    
                    # Convert to DataFrame
                    df = pd.DataFrame(normalized_jobs)
                    
                    # Save to Parquet
                    parquet_temp = temp_dir / f"{batch_name}.parquet.tmp"
            parquet_path = self.processed_dir / f"{batch_name}.parquet"
                    try:
                        df.to_parquet(parquet_temp, index=False)
                        parquet_temp.rename(parquet_path)
                        self.logger.debug(f"Saved Parquet data to {parquet_path}")
                    except Exception as e:
                        self.logger.error(f"Error saving Parquet: {str(e)}")

                    # Save to CSV
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

            # Update counters and log
            self.total_jobs_scraped += len(jobs)
            self.logger.info(
                f"Saved batch {batch_number} with {len(jobs)} jobs locally. "
                f"Total jobs scraped so far: {self.total_jobs_scraped}"
            )
            
            # Save batch metadata for tracking
            try:
                metadata = {
                    "batch_number": batch_number,
                    "batch_name": batch_name,
                    "timestamp": timestamp,
                    "job_count": len(jobs),
                    "files": {
                        "json": str(json_path),
                        "parquet": str(parquet_path) if file_save_success else None,
                        "csv": str(csv_path) if file_save_success else None
                    }
                }
                metadata_path = self.save_dir / "batch_metadata" 
                metadata_path.mkdir(exist_ok=True)
                with open(metadata_path / f"{batch_name}_metadata.json", "w") as f:
                    json.dump(metadata, f, indent=2, default=str)
            except Exception as meta_error:
                self.logger.warning(f"Error saving batch metadata: {str(meta_error)}")
                
        except Exception as e:
            self.logger.error(f"Error saving batch {batch_number}: {str(e)}")
            self.logger.error(traceback.format_exc())
            
            # Last-resort emergency save
            try:
                emergency_file = self.log_dir / f"emergency_batch_{batch_number}_{timestamp}.json"
                with open(emergency_file, "w") as f:
                    json.dump(jobs, f, default=str)
                self.logger.info(f"Emergency save: Dumped {len(jobs)} jobs to {emergency_file}")
            except Exception:
                pass

    async def job_stream(self, max_pages: Optional[int] = None) -> AsyncGenerator[Dict[str, Any], None]:
        """
        Creates an async generator that yields jobs as they are scraped.
        This allows for memory-efficient processing of large datasets.
        
        Args:
            max_pages (Optional[int]): Maximum number of pages to scrape.
            
        Yields:
            Dict[str, Any]: Individual job listing
        """
        page = 1
        total_pages = float('inf') if max_pages is None else max_pages
        
        async with aiohttp.ClientSession() as session:
            while page <= total_pages:
                try:
                    # Respect rate limits
                    if self.request_interval > 0:
                        await asyncio.sleep(self.request_interval)
                        
                    # Create payload for this page
                    payload = self.create_payload(page)
                    
                    # Fetch the page
                    response_data = await self.fetch_jobs(session, payload, page)
                    if not response_data:
                        self.logger.warning(f"Empty response for page {page}, stopping.")
                        break
                    
                    # Extract jobs from response
                    jobs = response_data.get("data", {}).get("jobPosts", [])
                    if not jobs:
                        self.logger.info(f"No jobs found on page {page}, stopping.")
                        break
                    
                    # Process each job and yield it
                    processed_jobs = await self.process_jobs(jobs)
                    for job in processed_jobs:
                        yield job
                    
                    # Update counters and check if we're done
                    self.total_jobs_scraped += len(processed_jobs)
                    
                    # Check for pagination end
                    has_next = response_data.get("data", {}).get("hasNextPage", False)
                    if not has_next:
                        self.logger.info(f"Reached last page at {page}")
                        break
                    
                    page += 1
                    
                except Exception as e:
                    await self._handle_error(page, e)
                    break
    
    async def scrape(self) -> Dict[str, Any]:
        """
        Run the entire scraping process with memory-efficient streaming approach.
        
        Returns:
            Dict[str, Any]: Dictionary containing scraping statistics and status.
        """
        start_time = time.time()
        status = "failed"  # Default status
        error_message = None
        total_time = 0
        stats = {}
        
        # Update monitoring data start time to current time
        self.monitoring_data["start_time"] = datetime.now().isoformat()
        
        try:
            # Phase 1: Initialization
            phase_start = time.time()
            self.logger.info("Starting scraping process initialization...")
            
            # Initialize DB connection if needed
            if self.db_enabled and self.db_manager:
                self.logger.info("Initializing database connection...")
                db_success = await self.db_manager.ensure_connection()
                if not db_success:
                    self.logger.warning("Database connection failed, falling back to file storage")
                    self.db_enabled = False
                    self.monitoring_data["errors"].append({
                        "phase": "initialization",
                        "type": "database_connection",
                        "message": "Failed to initialize database connection",
                        "timestamp": datetime.now().isoformat()
                    })
            
            # Update monitoring data for initialization phase
            phase_time = time.time() - phase_start
            self.monitoring_data["phases"]["initialization"] = {
                "status": "completed",
                "time": phase_time
            }
            
            # Phase 2: Scraping
            phase_start = time.time()
            self.logger.info("Starting job scraping...")
            
            # Create processor and consumer tasks
            try:
                # Set a task name for better debugging
                producer = asyncio.create_task(self._produce_jobs(), name="producer_task")
                consumer = asyncio.create_task(self._consume_jobs(), name="consumer_task")
                
                # Wait for both tasks to complete with timeout management
                max_runtime = self.scraper_config.get("max_runtime_seconds", 3600)  # Default 1 hour
                try:
                    await asyncio.wait_for(
                        asyncio.gather(producer, consumer),
                        timeout=max_runtime
                    )
                    self.logger.info(f"Scraping completed within time limit of {max_runtime}s")
                except asyncio.TimeoutError:
                    self.logger.warning(f"Scraping timed out after {max_runtime}s, terminating tasks")
                    if not producer.done():
                        producer.cancel()
                    if not consumer.done():
                        consumer.cancel()
                    
                    # Give tasks time to clean up after cancellation
                    try:
                        await asyncio.wait([producer, consumer], timeout=10)
                    except Exception:
                        pass
                    
                    self.monitoring_data["errors"].append({
                        "phase": "scraping",
                        "type": "timeout",
                        "message": f"Scraping timed out after {max_runtime}s",
                        "timestamp": datetime.now().isoformat()
                    })
            except Exception as e:
                self.logger.error(f"Error in scraping phase: {str(e)}")
                self.logger.error(traceback.format_exc())
                self.monitoring_data["errors"].append({
                    "phase": "scraping",
                    "type": "task_error",
                    "message": str(e),
                    "timestamp": datetime.now().isoformat()
                })
            
            # Update monitoring data for scraping phase
            phase_time = time.time() - phase_start
            self.monitoring_data["phases"]["scraping"] = {
                "status": "completed" if not self.monitoring_data["errors"] else "completed_with_errors",
                "time": phase_time,
                "jobs_processed": self.total_jobs_scraped,
                "batches_processed": self.current_batch
            }
            
            # Phase 3: Cleanup and statistics
            phase_start = time.time()
            self.logger.info("Performing cleanup and generating statistics...")
            
            # Log final statistics
            stats = await self._log_final_statistics(self.current_batch)
            
            # Update status based on errors
            if not self.monitoring_data["errors"]:
                status = "completed"
            else:
                status = "completed_with_errors"
                error_message = "; ".join(e["message"] for e in self.monitoring_data["errors"])
            
            # Update monitoring data for cleanup phase
            phase_time = time.time() - phase_start
            self.monitoring_data["phases"]["cleanup"] = {
                "status": "completed",
                "time": phase_time
            }
            
            # Calculate total runtime
            total_time = time.time() - start_time
            self.logger.info(f"Total scraping process time: {total_time:.2f}s")
            
        except Exception as e:
            self.logger.error(f"Unhandled error in scrape: {str(e)}")
            self.logger.error(traceback.format_exc())
            status = "failed"
            error_message = str(e)
            self.monitoring_data["errors"].append({
                "phase": "global",
                "type": "unhandled_exception",
                "message": str(e),
                "traceback": traceback.format_exc(),
                "timestamp": datetime.now().isoformat()
            })
            
            # Try to get stats even if there was an error
            try:
                stats = await self._log_final_statistics(self.current_batch)
            except Exception as stats_error:
                self.logger.error(f"Failed to generate statistics after error: {str(stats_error)}")
                stats = {
                    "total_jobs_scraped": self.total_jobs_scraped,
                    "pages_processed": self.current_batch,
                    "error": str(e)
                }
                
        finally:
            # Don't close DB connections here - will be done in run() method
            # Update monitoring data  
            self.monitoring_data["end_time"] = datetime.now().isoformat()
            self.monitoring_data["total_time"] = total_time
            self.monitoring_data["final_status"] = status
            
            try:
                monitor_file = self.log_dir / f"scrape_monitor_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
                with open(monitor_file, "w") as f:
                    json.dump(self.monitoring_data, f, indent=2, default=str)
                self.logger.info(f"Saved monitoring data to {monitor_file}")
            except Exception as e:
                self.logger.error(f"Failed to save monitoring data: {str(e)}")
                
        # Return comprehensive statistics
        return {
            "total_jobs": self.total_jobs_scraped,
            "pages_processed": self.current_batch,
            "status": status,
            "error": error_message,
            "runtime_seconds": total_time,
            "timestamp": datetime.now().isoformat(),
            "statistics": stats
        }
    
    async def _produce_jobs(self) -> None:
        """
        Producer task that scrapes jobs and puts them into the processing queue.
        """
        batch_id = str(uuid.uuid4())
        max_pages = self.scraper_config.get("max_pages", None)
        batch_size = self.scraper_config.get("batch_size", 100)
        current_batch = []
        jobs_produced = 0
        
        try:
            self.logger.info(f"Starting producer task, max_pages={max_pages}, batch_size={batch_size}")
            
            async for job in self.job_stream(max_pages):
                # Add job to current batch
                current_batch.append(job)
                jobs_produced += 1
                
                # When batch is full, put it in queue and start new batch
                if len(current_batch) >= batch_size:
                    self.logger.debug(f"Produced batch of {len(current_batch)} jobs")
                    await self.processing_queue.put((current_batch, batch_id))
                    current_batch = []
            
            # Put any remaining jobs in the queue
            if current_batch:
                self.logger.debug(f"Produced final batch of {len(current_batch)} jobs")
                await self.processing_queue.put((current_batch, batch_id))
                
            self.logger.info(f"Producer task completed, produced {jobs_produced} jobs in total")
                
            # Signal end of jobs with None
            await self.processing_queue.put((None, None))
            
        except Exception as e:
            self.logger.error(f"Error in producer task: {str(e)}")
            self.logger.error(traceback.format_exc())
            
            # Ensure we log any produced jobs that haven't been queued yet
            if current_batch:
                self.logger.warning(f"{len(current_batch)} jobs were produced but not queued due to error")
                
                # Try to save the jobs that were about to be queued
                try:
                    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
                    emergency_file = self.log_dir / f"unqueued_jobs_{timestamp}.json"
                    with open(emergency_file, "w") as f:
                        json.dump(current_batch, f, indent=2, default=str)
                    self.logger.info(f"Saved {len(current_batch)} unqueued jobs to {emergency_file}")
                except Exception as save_error:
                    self.logger.error(f"Could not save unqueued jobs: {str(save_error)}")
            
            # Ensure consumer can exit by sending None
            await self.processing_queue.put((None, None))
    
    async def _consume_jobs(self) -> None:
        """
        Consumer task that processes jobs from the queue and saves them.
        """
        total_batches_processed = 0
        total_jobs_processed = 0
        consecutive_errors = 0
        max_consecutive_errors = self.scraper_config.get("max_consumer_errors", 5)
        
        try:
            self.logger.info("Starting consumer task")
            while True:
                try:
                jobs_batch, batch_id = await self.processing_queue.get()
                
                # None signals end of jobs
                if jobs_batch is None:
                        self.logger.info("Received end-of-jobs signal, consumer task ending")
                    break
                
                # Process and save the batch
                    batch_size = len(jobs_batch)
                    self.logger.debug(f"Processing batch of {batch_size} jobs")
                    
                    try:
                        start_time = time.time()
                        processed_count = await self._process_jobs(jobs_batch)
                        process_time = time.time() - start_time
                        
                        # Update counters and logging
                        if processed_count > 0:
                            total_batches_processed += 1
                            total_jobs_processed += processed_count
                            consecutive_errors = 0  # Reset consecutive errors on success
                self.current_batch += 1
                
                            # Log performance for this batch
                            jobs_per_second = processed_count / process_time if process_time > 0 else 0
                            self.logger.info(
                                f"Batch {total_batches_processed} complete: {processed_count} jobs in "
                                f"{process_time:.2f}s ({jobs_per_second:.1f} jobs/s)"
                            )
                        else:
                            # Batch processing failed
                            consecutive_errors += 1
                            self.logger.warning(
                                f"Batch processing failed, consecutive errors: {consecutive_errors}/{max_consecutive_errors}"
                            )
                            
                            # Exit if too many consecutive errors
                            if consecutive_errors >= max_consecutive_errors:
                                self.logger.error(f"Too many consecutive batch processing errors ({consecutive_errors}), stopping consumer")
                                break
                    
                    except Exception as batch_error:
                        # Handle batch processing error
                        consecutive_errors += 1
                        self.logger.error(f"Error processing batch: {str(batch_error)}")
                        self.logger.error(traceback.format_exc())
                        
                        # Exit if too many consecutive errors
                        if consecutive_errors >= max_consecutive_errors:
                            self.logger.error(f"Too many consecutive batch processing errors ({consecutive_errors}), stopping consumer")
                            break
                    
                    # Mark task as done in the queue
                self.processing_queue.task_done()
                
                except asyncio.CancelledError:
                    # Handle cancellation
                    self.logger.warning("Consumer task was cancelled")
                    break
                    
                except Exception as queue_error:
                    # Error from queue operations
                    self.logger.error(f"Error in consumer task queue handling: {str(queue_error)}")
                    self.logger.error(traceback.format_exc())
                    consecutive_errors += 1
                    
                    if consecutive_errors >= max_consecutive_errors:
                        self.logger.error(f"Too many consecutive errors ({consecutive_errors}), stopping consumer")
                        break
                    
                    # Brief pause to prevent error loops
                    await asyncio.sleep(1)
                
            # Log final consumer statistics
            self.logger.info(
                f"Consumer task completed: processed {total_jobs_processed} jobs "
                f"in {total_batches_processed} batches"
            )
                
        except Exception as e:
            self.logger.error(f"Unhandled error in consumer task: {str(e)}")
            self.logger.error(traceback.format_exc())

        finally:
            # Update monitoring data
            if hasattr(self, 'monitoring_data'):
                self.monitoring_data["jobs_processed"] = total_jobs_processed
                self.monitoring_data["batches_processed"] = total_batches_processed

    async def _log_final_statistics(self, pages_processed: int) -> Dict[str, Any]:
        """
        Output final scraping statistics to logs and update config_manager.

        Args:
            pages_processed (int): Number of pages processed in this run.
            
        Returns:
            Dict[str, Any]: Dictionary containing the statistics.
        """
        end_time = datetime.now()
        
        # Calculate runtime from scraper init time if monitoring data is available
        try:
            start_time_str = self.monitoring_data.get("start_time", end_time.isoformat())
            start_time = datetime.fromisoformat(start_time_str)
            runtime_seconds = (end_time - start_time).total_seconds()
        except (ValueError, AttributeError):
            # Fallback if there's an issue with the start time
            self.logger.warning("Could not calculate runtime from monitoring data, using estimate")
            runtime_seconds = 0
        
        # Calculate rates and percentages (with safe division)
        jobs_per_page = self.total_jobs_scraped / max(1, pages_processed)
        jobs_per_second = self.total_jobs_scraped / max(1, runtime_seconds) if runtime_seconds > 0 else 0
        failed_request_pct = len(self.failed_requests) / max(1, pages_processed) * 100
        
        # Compile statistics
        stats = {
            "total_jobs_scraped": self.total_jobs_scraped,
            "pages_processed": pages_processed,
            "failed_requests": len(self.failed_requests),
            "failed_request_percentage": round(failed_request_pct, 2),
            "failed_request_pages": self.failed_requests[:10],  # First 10 for brevity
            "jobs_per_page": round(jobs_per_page, 2),
            "jobs_per_second": round(jobs_per_second, 2),
            "runtime_seconds": round(runtime_seconds, 2),
            "end_time": end_time.isoformat(),
            "memory_usage_mb": None,  # Will be populated if psutil is available
        }
        
        # Add memory usage if psutil is available
        try:
            import psutil
            process = psutil.Process(os.getpid())
            memory_mb = process.memory_info().rss / 1024 / 1024
            stats["memory_usage_mb"] = round(memory_mb, 2)
        except ImportError:
            self.logger.debug("psutil not available, skipping memory usage stats")
        except Exception as e:
            self.logger.warning(f"Could not get memory usage: {str(e)}")
        
        # Log the statistics
        self.logger.info("Scraping completed. Final statistics:")
        for k, v in stats.items():
            if k != "failed_request_pages":  # Skip verbose list
            self.logger.info(f"{k}: {v}")

        # If there were failed requests, log them in detail
        if self.failed_requests:
            self.logger.warning(f"Failed requests: {len(self.failed_requests)} pages")
            if len(self.failed_requests) <= 10:
                self.logger.warning(f"Failed pages: {', '.join(map(str, self.failed_requests))}")
            else:
                self.logger.warning(f"First 10 failed pages: {', '.join(map(str, self.failed_requests[:10]))}")
        
        # Save state to persistent storage
        try:
            self.config_manager.save_state({
                "last_run_stats": stats, 
                "scraping_complete": True,
                "last_run": end_time.isoformat()
            })
            self.logger.info("Statistics saved to state file")
        except Exception as e:
            self.logger.error(f"Failed to save final statistics: {str(e)}")
        
        return stats

    async def _handle_error(self, page: int, error: Exception) -> None:
        """
        Handle scraping errors by logging, tracking state, and scheduling a retry if needed.

        Args:
            page (int): The page number where the error occurred.
            error (Exception): The exception thrown.
        """
        # Extract error details
        error_type = type(error).__name__
        error_message = str(error)
        error_traceback = traceback.format_exc()
        
        self.logger.error(f"Error on page {page}: {error_type} - {error_message}")
        self.logger.error(error_traceback)
        
        # Add to failed requests list
        self.failed_requests.append(page)

        # Categorize the error
        is_connection_error = isinstance(error, (aiohttp.ClientConnectionError, 
                                               asyncio.TimeoutError))
        is_http_error = isinstance(error, aiohttp.ClientResponseError)
        is_parsing_error = isinstance(error, (json.JSONDecodeError, KeyError, TypeError))
        
        # Create detailed error state for tracking
        error_state = {
            "last_error": {
                "page": page,
                "timestamp": datetime.now().isoformat(),
                "error_type": error_type,
                "error_message": error_message,
                "error_category": "connection" if is_connection_error else
                                 "http" if is_http_error else
                                 "parsing" if is_parsing_error else
                                 "unknown"
            },
            "failed_requests": self.failed_requests,
            "total_failures": len(self.failed_requests)
        }
        
        # Log error state
        self.logger.info(f"Updated error state: {error_state}")
        
        # Save error state to disk for analysis
        error_log_path = self.log_dir / f"error_state_{datetime.now().strftime('%Y%m%d_%H%M%S')}.json"
        try:
            with open(error_log_path, "w") as f:
                json.dump(error_state, f, indent=2, default=str)
            self.logger.info(f"Saved error details to {error_log_path}")
        except Exception as e:
            self.logger.warning(f"Could not save error log: {str(e)}")
        
        # Decide whether to continue
        if len(self.failed_requests) > self.scraper_config.get("max_failures", 10):
            self.logger.error("Too many failures, stopping scraper")
            # Raise a specific exception to signal that scraping should stop
            raise TooManyFailuresError(f"Scraping stopped after {len(self.failed_requests)} failures")

    async def run(self) -> Dict[str, Union[int, str, Dict]]:
        """
        A convenience method to initialize, start scraping, and handle cleanup.

        Returns:
            Dict[str, Union[int, str, Dict]]: Final scraping statistics.
        """
        try:
            self.logger.info("Starting job scraper run().")
            
            # Reset monitoring data at the start of each run
            self.monitoring_data = {
                "start_time": datetime.now().isoformat(),
                "phases": {
                    "initialization": {"status": "pending", "time": 0},
                    "scraping": {"status": "pending", "time": 0},
                    "cleanup": {"status": "pending", "time": 0}
                },
                "jobs_processed": 0,
                "batches_processed": 0,
                "errors": []
            }
            
            # Initialize components
            init_success = await self.initialize()
            if not init_success:
                self.logger.error("Failed to initialize scraper.")
            return {
                    "total_jobs": 0,
                    "pages_processed": 0,
                    "status": "failed",
                    "error": "Initialization failed",
                }
            
            # Run the scraping process
            result = await self.scrape()
            self.logger.info("Job scraper completed successfully.")
            return result
            
        except Exception as e:
            self.logger.error(f"Error during scraper execution: {str(e)}")
            self.logger.error(traceback.format_exc())
            return {
                "total_jobs": self.total_jobs_scraped,
                "pages_processed": self.current_batch,
                "status": "failed",
                "error": str(e),
            }
        finally:
            # Close DB connections if used
            if self.db_enabled and self.db_manager:
                try:
                await self.db_manager.close()
                except Exception as e:
                    self.logger.error(f"Error closing database connection: {str(e)}")


class TooManyFailuresError(Exception):
    """Exception raised when too many pages have failed during scraping."""
    pass
