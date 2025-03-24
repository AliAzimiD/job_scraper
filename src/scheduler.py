import asyncio
import logging
from datetime import datetime, time, timedelta
from pathlib import Path
from typing import Optional, Dict, Any, List
import traceback
import time as time_module

from .scraper import JobScraper
from .log_setup import get_logger

class JobScraperScheduler:
    """
    A scheduler that runs the JobScraper at a regular interval within specified hours.
    Supports time-of-day restrictions to run only during certain hours.
    """

    def __init__(
        self,
        config_path: str = "config/api_config.yaml",
        base_dir: str = "job_data",
        interval_minutes: int = 60,
        start_hour: int = 6,
        end_hour: int = 23,
        db_connection_string: Optional[str] = None,
    ) -> None:
        """
        Initialize the scheduler with the desired interval, time restrictions, and config paths.

        Args:
            config_path (str): Path to the config file for the JobScraper.
            base_dir (str): Base directory for data.
            interval_minutes (int): Interval in minutes between each run.
            start_hour (int): Hour of day to start allowing scrapes (0-23).
            end_hour (int): Hour of day to stop allowing scrapes (0-23).
            db_connection_string (Optional[str]): Database connection string.
        """
        self.config_path = config_path
        self.base_dir = Path(base_dir)
        self.interval_minutes = interval_minutes
        self.start_hour = start_hour
        self.end_hour = end_hour
        self.db_connection_string = db_connection_string
        self.logger = get_logger("JobScraperScheduler")
        
        # Create directories if they don't exist
        self.base_dir.mkdir(parents=True, exist_ok=True)
        
        # Statistics for monitoring
        self.stats: Dict[str, Any] = {
            "runs": 0,
            "successful_runs": 0,
            "failed_runs": 0,
            "last_run_time": None,
            "last_run_status": None,
            "last_run_duration": None,
            "last_error": None,
            "jobs_collected": 0,
            "runs_outside_hours": 0,
        }
        
        # Runtime control flags
        self.shutdown_requested = False
        self.pause_requested = False

    def request_shutdown(self) -> None:
        """
        Signal the scheduler to shutdown gracefully after the current run.
        """
        self.logger.info("Shutdown requested")
        self.shutdown_requested = True
        
    def pause(self) -> None:
        """
        Pause the scheduler.
        """
        self.logger.info("Pause requested")
        self.pause_requested = True
        
    def resume(self) -> None:
        """
        Resume the scheduler after pause.
        """
        self.logger.info("Resuming scheduler")
        self.pause_requested = False

    def get_stats(self) -> Dict[str, Any]:
        """
        Get the current statistics of the scheduler.
        
        Returns:
            Dict[str, Any]: Statistics dictionary
        """
        return self.stats

    def is_within_operating_hours(self) -> bool:
        """
        Check if the current time is within the allowed operating hours.
        
        Returns:
            bool: True if within operating hours, False otherwise
        """
        now = datetime.now()
        current_hour = now.hour
        
        # Check if current hour is within range
        return self.start_hour <= current_hour <= self.end_hour

    async def wait_until_operating_hours(self) -> None:
        """
        Wait until the next operating window.
        """
        while not self.is_within_operating_hours():
            now = datetime.now()
            current_hour = now.hour
            
            # Calculate next operating time
            if current_hour < self.start_hour:
                # If it's before start_hour, wait until start_hour today
                next_run = now.replace(hour=self.start_hour, minute=0, second=0, microsecond=0)
            else:
                # If it's after end_hour, wait until start_hour tomorrow
                next_run = now.replace(hour=self.start_hour, minute=0, second=0, microsecond=0) + timedelta(days=1)
            
            wait_seconds = (next_run - now).total_seconds()
            
            self.logger.info(
                f"Outside operating hours ({self.start_hour}:00-{self.end_hour}:00). "
                f"Waiting {wait_seconds:.0f} seconds until {next_run.strftime('%Y-%m-%d %H:%M:%S')}"
            )
            
            # Wait in small increments to allow for graceful shutdown
            remaining_seconds = wait_seconds
            while remaining_seconds > 0 and not self.shutdown_requested:
                await asyncio.sleep(min(60, remaining_seconds))
                remaining_seconds -= 60
                
                if self.shutdown_requested:
                    self.logger.info("Shutdown requested during wait period")
                    return
                    
            self.stats["runs_outside_hours"] += 1
            
            # If we finished waiting, check again
            if not self.shutdown_requested:
                self.logger.info("Entering operating hours, continuing with scheduler")

    async def run(self) -> None:
        """
        Continuously run the scraper in a loop, respecting operating hours and interval.
        """
        self.logger.info(
            f"Starting JobScraperScheduler (interval: {self.interval_minutes} minutes, "
            f"hours: {self.start_hour}:00-{self.end_hour}:00)"
        )
        
        while not self.shutdown_requested:
            try:
                # Check if paused
                if self.pause_requested:
                    self.logger.info("Scheduler is paused. Waiting...")
                    await asyncio.sleep(60)  # Check every minute if we should resume
                    continue
                
                # Check if we're within operating hours
                if not self.is_within_operating_hours():
                    await self.wait_until_operating_hours()
                    if self.shutdown_requested:
                        break
                    continue
                
                # Start the scraping run
                self.logger.info("Starting scraping run in scheduler.")
                start_time = time_module.time()
                self.stats["runs"] += 1
                self.stats["last_run_time"] = datetime.now().isoformat()
                
                # Initialize scraper
                scraper = JobScraper(
                    config_path=self.config_path,
                    save_dir=str(self.base_dir),
                )
                
                # Initialize if needed
                await scraper.initialize()
                
                # Run the scraper
                try:
                    results = await scraper.run()
                    
                    # Update statistics
                    end_time = time_module.time()
                    duration = end_time - start_time
                    self.stats["last_run_duration"] = duration
                    self.stats["successful_runs"] += 1
                    self.stats["last_run_status"] = "success"
                    self.stats["jobs_collected"] += results.get("total_jobs", 0)
                    
                    self.logger.info(
                        f"Completed scraping run. Duration: {duration:.2f} seconds. "
                        f"Status: {results.get('status')}. "
                        f"Jobs collected: {results.get('total_jobs', 0)}. "
                        f"Total jobs so far: {self.stats['jobs_collected']}"
                    )
                except Exception as e:
                    # Handle scraper errors
                    end_time = time_module.time()
                    duration = end_time - start_time
                    self.stats["last_run_duration"] = duration
                    self.stats["failed_runs"] += 1
                    self.stats["last_run_status"] = "error"
                    self.stats["last_error"] = str(e)
                    
                    self.logger.error(
                        f"Error in scraper run: {str(e)}. Duration: {duration:.2f} seconds."
                    )
                    self.logger.debug(traceback.format_exc())
                
                # Determine wait time until next run
                now = datetime.now()
                next_run_time = now + timedelta(minutes=self.interval_minutes)
                
                # Check if the next run would fall outside operating hours
                next_run_hour = next_run_time.hour
                if not (self.start_hour <= next_run_hour <= self.end_hour):
                    # The next run would be outside hours, so wait until the start hour of the next day
                    next_day = now.date() + timedelta(days=1)
                    next_run_time = datetime.combine(next_day, time(self.start_hour, 0))
                
                wait_seconds = (next_run_time - now).total_seconds()
                
                self.logger.info(
                    f"Waiting {wait_seconds:.0f} seconds until next run at {next_run_time.strftime('%Y-%m-%d %H:%M:%S')}"
                )
                
                # Wait in smaller chunks to allow for clean shutdown
                await self._wait_with_check(wait_seconds)
                
            except Exception as e:
                self.logger.error(f"Error in JobScraperScheduler: {str(e)}")
                self.logger.debug(traceback.format_exc())
                self.stats["last_error"] = str(e)
                
                # Wait a minute before trying again
                await asyncio.sleep(60)
        
        self.logger.info("JobScraperScheduler shutdown completed")

    async def _wait_with_check(self, seconds: float) -> None:
        """
        Wait for the specified number of seconds, but check periodically for shutdown or pause.
        
        Args:
            seconds: Number of seconds to wait
        """
        check_interval = 30  # Check every 30 seconds
        remaining = seconds
        
        while remaining > 0 and not self.shutdown_requested and not self.pause_requested:
            wait_time = min(check_interval, remaining)
            await asyncio.sleep(wait_time)
            remaining -= wait_time
            
            if self.shutdown_requested:
                self.logger.info("Shutdown requested during wait period")
                return
                
            if self.pause_requested:
                self.logger.info("Pause requested during wait period")
                return
