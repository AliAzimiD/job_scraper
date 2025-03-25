"""
Health Check Module for Job Scraper Application

This module provides health check endpoints for the application, monitoring
critical components such as database, Redis cache, and server status.
"""

import time
import logging
import psutil
import threading
from typing import Dict, Any, List, Optional

from flask import Response, jsonify

from app.db.manager import get_db_manager
from app.utils.cache import get_cache
from app.utils.config import get_config


logger = logging.getLogger(__name__)


class HealthStatus:
    """Health status constants."""
    OK = "ok"
    WARNING = "warning"
    ERROR = "error"
    UNKNOWN = "unknown"


class HealthCheck:
    """Health check manager for the job scraper application.
    
    This class provides health check functionality to monitor the status of
    critical application components and dependencies.
    """
    
    def __init__(self):
        """Initialize the health check manager."""
        self.config = get_config()
        self.db_manager = get_db_manager()
        self.cache = get_cache()
        self.last_check = 0
        self.cached_status = {"status": HealthStatus.UNKNOWN}
        self.cache_ttl = self.config.get('app.health_cache_ttl', 10)
        
        # Start background thread for active health checks
        if self.config.get('app.enable_active_health_checks', False):
            self._start_background_checks()
    
    def _start_background_checks(self):
        """Start background thread for periodic health checks."""
        interval = self.config.get('app.health_check_interval', 60)
        
        def check_periodically():
            while True:
                try:
                    self.check_all(force=True)
                except Exception as e:
                    logger.error(f"Error in background health check: {str(e)}")
                
                time.sleep(interval)
        
        thread = threading.Thread(target=check_periodically, daemon=True)
        thread.start()
        logger.info(f"Started background health checks (interval: {interval}s)")
    
    def check_all(self, force: bool = False) -> Dict[str, Any]:
        """Check the health of all components.
        
        Args:
            force: Force a new check even if cached results are available
            
        Returns:
            Health status dictionary
        """
        # Return cached results if still valid
        if not force and (time.time() - self.last_check) < self.cache_ttl:
            return self.cached_status
        
        status = {
            "status": HealthStatus.OK,
            "timestamp": int(time.time()),
            "components": {}
        }
        
        # Check database
        db_status = self.check_database()
        status["components"]["database"] = db_status
        
        # Check Redis cache
        cache_status = self.check_cache()
        status["components"]["cache"] = cache_status
        
        # Check system resources
        system_status = self.check_system_resources()
        status["components"]["system"] = system_status
        
        # Determine overall status (worst of all component statuses)
        component_statuses = [
            comp.get("status", HealthStatus.UNKNOWN) 
            for comp in status["components"].values()
        ]
        
        if HealthStatus.ERROR in component_statuses:
            status["status"] = HealthStatus.ERROR
        elif HealthStatus.WARNING in component_statuses:
            status["status"] = HealthStatus.WARNING
        elif HealthStatus.UNKNOWN in component_statuses and len(component_statuses) > 0:
            status["status"] = HealthStatus.WARNING
        
        # Cache the results
        self.cached_status = status
        self.last_check = time.time()
        
        return status
    
    def check_database(self) -> Dict[str, Any]:
        """Check database health.
        
        Returns:
            Database health status
        """
        status = {
            "status": HealthStatus.UNKNOWN,
            "message": "Database check not performed"
        }
        
        try:
            # If DB is not initialized, try to initialize it
            if not getattr(self.db_manager, '_initialized', False):
                try:
                    import asyncio
                    asyncio.get_event_loop().run_until_complete(self.db_manager.initialize())
                except Exception as e:
                    status["status"] = HealthStatus.ERROR
                    status["message"] = f"Database initialization failed: {str(e)}"
                    return status
            
            # Check connection by running a simple query
            try:
                import asyncio
                result = asyncio.get_event_loop().run_until_complete(
                    self.db_manager.execute_query("SELECT 1 as test")
                )
                if result and result[0].get('test') == 1:
                    status["status"] = HealthStatus.OK
                    status["message"] = "Database connection successful"
                else:
                    status["status"] = HealthStatus.WARNING
                    status["message"] = "Database connected but query returned unexpected result"
            except Exception as e:
                status["status"] = HealthStatus.ERROR
                status["message"] = f"Database query failed: {str(e)}"
        
        except Exception as e:
            status["status"] = HealthStatus.ERROR
            status["message"] = f"Database health check failed: {str(e)}"
        
        return status
    
    def check_cache(self) -> Dict[str, Any]:
        """Check Redis cache health.
        
        Returns:
            Cache health status
        """
        status = {
            "status": HealthStatus.UNKNOWN,
            "message": "Cache check not performed"
        }
        
        try:
            if self.cache.is_available():
                # Try to set and get a test key
                test_key = "health_check_test"
                test_value = f"test_{time.time()}"
                
                if self.cache.set(test_key, test_value):
                    cached_value = self.cache.get(test_key)
                    if cached_value == test_value:
                        status["status"] = HealthStatus.OK
                        status["message"] = "Cache connection successful"
                    else:
                        status["status"] = HealthStatus.WARNING
                        status["message"] = "Cache connected but value retrieval failed"
                else:
                    status["status"] = HealthStatus.WARNING
                    status["message"] = "Cache connected but value storage failed"
            else:
                status["status"] = HealthStatus.WARNING
                status["message"] = "Cache not available"
        
        except Exception as e:
            status["status"] = HealthStatus.ERROR
            status["message"] = f"Cache health check failed: {str(e)}"
        
        return status
    
    def check_system_resources(self) -> Dict[str, Any]:
        """Check system resources.
        
        Returns:
            System resources health status
        """
        status = {
            "status": HealthStatus.UNKNOWN,
            "message": "System resources check not performed",
            "metrics": {}
        }
        
        try:
            # Get CPU usage
            cpu_percent = psutil.cpu_percent(interval=0.1)
            cpu_threshold = self.config.get('monitoring.cpu_warning_threshold', 80)
            
            # Get memory usage
            memory = psutil.virtual_memory()
            memory_percent = memory.percent
            memory_threshold = self.config.get('monitoring.memory_warning_threshold', 80)
            
            # Get disk usage
            disk = psutil.disk_usage('/')
            disk_percent = disk.percent
            disk_threshold = self.config.get('monitoring.disk_warning_threshold', 80)
            
            # Store metrics
            status["metrics"] = {
                "cpu_percent": cpu_percent,
                "memory_percent": memory_percent,
                "disk_percent": disk_percent,
                "memory_available_mb": round(memory.available / (1024 * 1024), 2),
                "disk_free_gb": round(disk.free / (1024 * 1024 * 1024), 2)
            }
            
            # Determine status based on thresholds
            if (cpu_percent > cpu_threshold or 
                memory_percent > memory_threshold or 
                disk_percent > disk_threshold):
                
                status["status"] = HealthStatus.WARNING
                warnings = []
                
                if cpu_percent > cpu_threshold:
                    warnings.append(f"CPU usage ({cpu_percent}%) above threshold ({cpu_threshold}%)")
                
                if memory_percent > memory_threshold:
                    warnings.append(f"Memory usage ({memory_percent}%) above threshold ({memory_threshold}%)")
                
                if disk_percent > disk_threshold:
                    warnings.append(f"Disk usage ({disk_percent}%) above threshold ({disk_threshold}%)")
                
                status["message"] = "; ".join(warnings)
            else:
                status["status"] = HealthStatus.OK
                status["message"] = "System resources normal"
        
        except Exception as e:
            status["status"] = HealthStatus.ERROR
            status["message"] = f"System resources check failed: {str(e)}"
        
        return status


# Create a singleton instance
health_check = HealthCheck()


def get_health_check() -> HealthCheck:
    """Get the health check instance.
    
    Returns:
        HealthCheck instance
    """
    return health_check


def create_health_endpoints(app):
    """Create health check endpoints for the Flask application.
    
    Args:
        app: Flask application instance
    """
    @app.route('/health')
    def health():
        """Simple health check endpoint."""
        status = health_check.check_all()
        return jsonify({"status": status["status"]})
    
    @app.route('/health/detailed')
    def health_detailed():
        """Detailed health check endpoint."""
        status = health_check.check_all()
        return jsonify(status)
