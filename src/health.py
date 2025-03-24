import asyncio
import logging
import json
import os
import time
from datetime import datetime, timedelta
from typing import Optional, Tuple, Any, Dict, List
from collections import deque

import aiohttp
from aiohttp import web
import psutil

from .db_manager import DatabaseManager
from .log_setup import get_logger

logger = get_logger("health_check")

class HealthCheck:
    """
    Provides an extensive health check and metrics API using aiohttp.
    Includes performance monitoring, error tracking, and self-healing capabilities.

    Attributes:
        db_manager (DatabaseManager): An instance managing database connectivity.
        app (web.Application): The aiohttp application object.
        error_history: Rolling window of recent errors for tracking.
    """

    def __init__(self, db_manager: DatabaseManager) -> None:
        """
        Initialize the HealthCheck service with the given DatabaseManager.

        Args:
            db_manager (DatabaseManager): Instance managing DB operations.
        """
        self.db_manager = db_manager
        self.app = web.Application()
        
        # Metrics and health status tracking
        self.metrics: Dict[str, Any] = {
            "start_time": datetime.now(),
            "uptime_seconds": 0,
            "http_requests": 0,
            "api_errors": 0,
            "db_errors": 0,
            "scraper_runs": 0,
            "jobs_scraped": 0,
            "last_scrape_time": None,
            "scraper_status": "unknown"
        }
        
        # Error tracking with timestamp, message, count
        self.error_history = deque(maxlen=100)
        self.error_counts: Dict[str, int] = {}
        
        # Performance tracking
        self.performance_history: Dict[str, deque] = {
            "memory_usage": deque(maxlen=60),
            "cpu_usage": deque(maxlen=60),
            "db_response_time": deque(maxlen=60)
        }
        
        # Periodic health status updates
        self.health_status = "unknown"
        self.health_check_interval = 60  # seconds
        self.last_health_check = 0
        
        # Register routes
        self.app.add_routes([
            web.get('/health', self.health_check),
            web.get('/metrics', self.metrics_endpoint),
            web.get('/stats', self.detailed_stats),
            web.get('/errors', self.error_logs),
            web.get('/performance', self.performance_metrics)
        ])
        
        # Start background tasks
        self.background_tasks = []

    async def start(self, host: str = "0.0.0.0", port: int = 8080) -> Tuple[web.AppRunner, web.TCPSite]:
        """
        Start the aiohttp server for health checks and metrics,
        and begin periodic background monitoring tasks.

        Args:
            host (str): Host interface.
            port (int): Port to listen on.

        Returns:
            Tuple[web.AppRunner, web.TCPSite]: references to the created runner and site.
        """
        # Start the metrics collection background task
        self.background_tasks.append(asyncio.create_task(self._collect_metrics()))
        
        # Start the web server
        runner = web.AppRunner(self.app)
        await runner.setup()
        site = web.TCPSite(runner, host, port)
        await site.start()
        logger.info(f"Health check server started on http://{host}:{port}")
        return runner, site
        
    async def _collect_metrics(self) -> None:
        """
        Background task that periodically collects metrics data.
        """
        while True:
            try:
                # Update uptime
                self.metrics["uptime_seconds"] = (datetime.now() - self.metrics["start_time"]).total_seconds()
                
                # Collect system metrics
                memory_info = self._get_memory_usage()
                cpu_percent = psutil.cpu_percent(interval=1)
                
                # Store in history for trend analysis
                self.performance_history["memory_usage"].append({
                    "timestamp": datetime.now().isoformat(),
                    "value": memory_info["rss_mb"]
                })
                self.performance_history["cpu_usage"].append({
                    "timestamp": datetime.now().isoformat(),
                    "value": cpu_percent
                })
                
                # Check database response time
                start_time = time.time()
                db_healthy = await self._check_db_health()
                response_time = time.time() - start_time
                
                self.performance_history["db_response_time"].append({
                    "timestamp": datetime.now().isoformat(),
                    "value": response_time
                })
                
                # Determine overall health
                current_time = time.time()
                if current_time - self.last_health_check > self.health_check_interval:
                    self.health_status = await self._determine_health_status()
                    self.last_health_check = current_time
                
                # Sleep for a bit before next collection
                await asyncio.sleep(15)
                
            except Exception as e:
                logger.error(f"Error in metrics collection: {str(e)}")
                self._record_error("metrics_collection", str(e))
                await asyncio.sleep(30)  # Back off on error
                
    async def _check_db_health(self) -> bool:
        """
        Check if the database is responding properly.
        
        Returns:
            bool: True if database is healthy
        """
        try:
            if not self.db_manager.is_connected:
                await self.db_manager.ensure_connection()
                
            if self.db_manager.is_connected:
                job_count = await self.db_manager.get_job_count()
                return True
            return False
        except Exception as e:
            self._record_error("db_health_check", str(e))
            self.metrics["db_errors"] += 1
            return False
    
    async def _determine_health_status(self) -> str:
        """
        Determine the overall health status based on all metrics.
        
        Returns:
            str: One of "healthy", "degraded", "unhealthy"
        """
        # Check database
        db_healthy = await self._check_db_health()
        
        # Check memory usage (warn at 85%, critical at 95%)
        memory_percent = psutil.virtual_memory().percent
        memory_critical = memory_percent > 95
        memory_warning = memory_percent > 85
        
        # Check recent error rate (over last 5 minutes)
        error_threshold = 5
        recent_errors = sum(1 for e in self.error_history 
                          if datetime.now() - e["timestamp"] < timedelta(minutes=5))
        high_error_rate = recent_errors > error_threshold
        
        # Determine overall status
        if not db_healthy or memory_critical or high_error_rate:
            return "unhealthy"
        elif memory_warning:
            return "degraded"
        else:
            return "healthy"
    
    def _record_error(self, error_type: str, message: str) -> None:
        """
        Record an error for tracking.
        
        Args:
            error_type (str): Category of error
            message (str): Error message
        """
        error_entry = {
            "timestamp": datetime.now(),
            "type": error_type,
            "message": message
        }
        self.error_history.append(error_entry)
        
        # Update error counts by type
        if error_type not in self.error_counts:
            self.error_counts[error_type] = 0
        self.error_counts[error_type] += 1

    async def health_check(self, request: web.Request) -> web.Response:
        """
        Basic health check endpoint. Verifies database connectivity and returns a JSON status object.

        Args:
            request (web.Request): Incoming HTTP request (unused).

        Returns:
            web.Response: JSON response containing health status.
        """
        self.metrics["http_requests"] += 1
        
        try:
            db_healthy = await self._check_db_health()
            job_count = await self.db_manager.get_job_count() if db_healthy else None
            
            # Get current health status
            status = self.health_status
            if time.time() - self.last_health_check > self.health_check_interval:
                status = await self._determine_health_status()
                self.health_status = status
                self.last_health_check = time.time()
            
            data = {
                "status": status,
                "database": "connected" if db_healthy else "disconnected",
                "job_count": job_count,
                "uptime_seconds": self.metrics["uptime_seconds"],
                "memory_usage_percent": psutil.virtual_memory().percent,
                "cpu_usage_percent": psutil.cpu_percent(interval=None),
                "timestamp": str(datetime.now()),
            }
            
            # Set appropriate HTTP status
            http_status = 200 if status == "healthy" else 503 if status == "unhealthy" else 429
            
            return web.json_response(data, status=http_status)
        
        except Exception as e:
            logger.error(f"Health check failed: {str(e)}")
            self._record_error("health_check", str(e))
            return web.json_response({
                "status": "unhealthy",
                "error": str(e),
                "timestamp": str(datetime.now()),
            }, status=500)

    async def metrics_endpoint(self, request: web.Request) -> web.Response:
        """
        Metrics endpoint to gather and expose custom stats about the scraper (e.g., job counts).

        Args:
            request (web.Request): Incoming HTTP request (unused).

        Returns:
            web.Response: JSON response with metrics data.
        """
        self.metrics["http_requests"] += 1
        
        try:
            # Try to get latest job stats from DB
            job_stats = {}
            if await self._check_db_health():
                job_stats = await self.db_manager.get_job_stats()
                
            # Get system metrics
            system_metrics = {
                "memory": self._get_memory_usage(),
                "cpu_percent": psutil.cpu_percent(interval=None),
                "disk_usage_percent": psutil.disk_usage("/").percent,
            }
            
            # Full metrics response
            data = {
                "metrics": {
                    "jobs": job_stats,
                    "system": system_metrics,
                    "scraper": {
                        "uptime_seconds": self.metrics["uptime_seconds"],
                        "http_requests": self.metrics["http_requests"],
                        "api_errors": self.metrics["api_errors"],
                        "db_errors": self.metrics["db_errors"],
                        "scraper_runs": self.metrics["scraper_runs"],
                        "jobs_scraped": self.metrics["jobs_scraped"],
                        "last_scrape_time": self.metrics["last_scrape_time"],
                        "error_counts": self.error_counts
                    }
                },
                "timestamp": str(datetime.now()),
            }
            return web.json_response(data)
            
        except Exception as e:
            logger.error(f"Metrics endpoint failed: {str(e)}")
            self._record_error("metrics_endpoint", str(e))
            return web.json_response({
                "status": "error",
                "error": str(e),
            }, status=500)

    async def detailed_stats(self, request: web.Request) -> web.Response:
        """
        Provides more detailed statistics about recent scraping operations.
        
        Args:
            request (web.Request): Incoming HTTP request.
            
        Returns:
            web.Response: JSON response with detailed stats.
        """
        self.metrics["http_requests"] += 1
        
        try:
            # Get batch stats from DB if available
            batch_stats = []
            if await self._check_db_health():
                async with self.db_manager.pool.acquire() as conn:
                    rows = await conn.fetch(f"""
                        SELECT batch_id, batch_date, job_count, 
                               processing_time, status, created_at, completed_at
                        FROM {self.db_manager.schema}.job_batches
                        ORDER BY batch_date DESC LIMIT 20
                    """)
                    
                    for row in rows:
                        batch_stats.append(dict(row))
            
            data = {
                "batch_history": batch_stats,
                "overall_metrics": {
                    "total_jobs": await self.db_manager.get_job_count() if self.db_manager.is_connected else None,
                    "uptime_hours": round(self.metrics["uptime_seconds"] / 3600, 2),
                    "error_rate": len(self.error_history) / (self.metrics["http_requests"] + 1)
                },
                "timestamp": str(datetime.now())
            }
            
            return web.json_response(data)
            
        except Exception as e:
            logger.error(f"Detailed stats endpoint failed: {str(e)}")
            self._record_error("detailed_stats", str(e))
            return web.json_response({
                "status": "error",
                "error": str(e)
            }, status=500)
            
    async def error_logs(self, request: web.Request) -> web.Response:
        """
        Provides a history of recent errors for debugging.
        
        Args:
            request (web.Request): Incoming HTTP request.
            
        Returns:
            web.Response: JSON response with error logs.
        """
        self.metrics["http_requests"] += 1
        
        try:
            # Convert error history to serializable format
            error_list = []
            for error in self.error_history:
                error_list.append({
                    "timestamp": error["timestamp"].isoformat(),
                    "type": error["type"],
                    "message": error["message"]
                })
            
            data = {
                "errors": error_list,
                "error_counts": self.error_counts,
                "timestamp": str(datetime.now())
            }
            
            return web.json_response(data)
            
        except Exception as e:
            logger.error(f"Error logs endpoint failed: {str(e)}")
            self._record_error("error_logs", str(e))
            return web.json_response({
                "status": "error",
                "error": str(e)
            }, status=500)
            
    async def performance_metrics(self, request: web.Request) -> web.Response:
        """
        Provides performance metrics over time for trend analysis.
        
        Args:
            request (web.Request): Incoming HTTP request.
            
        Returns:
            web.Response: JSON response with performance metrics.
        """
        self.metrics["http_requests"] += 1
        
        try:
            data = {
                "performance": {
                    "memory_usage": list(self.performance_history["memory_usage"]),
                    "cpu_usage": list(self.performance_history["cpu_usage"]),
                    "db_response_time": list(self.performance_history["db_response_time"])
                },
                "system_info": {
                    "total_memory_mb": psutil.virtual_memory().total / (1024 * 1024),
                    "cpu_count": psutil.cpu_count(),
                    "python_version": sys.version if 'sys' in globals() else "unknown"
                },
                "timestamp": str(datetime.now())
            }
            
            return web.json_response(data)
            
        except Exception as e:
            logger.error(f"Performance metrics endpoint failed: {str(e)}")
            self._record_error("performance_metrics", str(e))
            return web.json_response({
                "status": "error",
                "error": str(e)
            }, status=500)

    def _get_memory_usage(self) -> dict:
        """
        Gather memory usage stats for the current process.

        Returns:
            dict: Dictionary of RSS and VMS usage in MB.
        """
        process = psutil.Process(os.getpid())
        return {
            "rss_mb": process.memory_info().rss / (1024 * 1024),
            "vms_mb": process.memory_info().vms / (1024 * 1024),
        }

    def update_scraper_metrics(self, metrics: Dict[str, Any]) -> None:
        """
        Update metrics from a scraper run.
        
        Args:
            metrics: Dict with metric updates
        """
        for key, value in metrics.items():
            if key in self.metrics:
                self.metrics[key] = value
        
        # Update last scrape time
        self.metrics["last_scrape_time"] = datetime.now().isoformat()
        self.metrics["scraper_runs"] += 1
