"""Admin API functions for the job scraper."""
import os
import json
import logging
import asyncio
import time
from datetime import datetime
from typing import Dict, List, Any, Optional

# Setup logger
logger = logging.getLogger(__name__)

# Global variables
scrape_running = False
last_scrape_time = None
scrape_task = None

# Get the project root directory
PROJECT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Config file path
CONFIG_FILE = os.path.join(PROJECT_ROOT, "config", "config.json")

# Define placeholder/fallback classes in case the actual implementations aren't available
try:
    # Try to import the actual DatabaseManager
    from .db_manager import DatabaseManager
except ImportError:
    logger.warning("Could not import DatabaseManager, using fallback implementation")
    
    class DatabaseManager:
        """Fallback DatabaseManager implementation."""
        
        async def get_job_count(self) -> int:
            """Get the total job count."""
            logger.warning("Using fallback DatabaseManager.get_job_count()")
            return 0
            
        async def get_recent_jobs(self, limit: int = 10) -> List[Dict[str, Any]]:
            """Get recent jobs with limit."""
            logger.warning("Using fallback DatabaseManager.get_recent_jobs()")
            return [{"title": "Example Job", "company": "Example Corp", "location": "Remote", "date": "2023-01-01"}]

try:
    # Try to import the actual ConfigManager
    from .config_manager import ConfigManager as ActualConfigManager
    
    class ConfigManager(ActualConfigManager):
        """Wrapper for actual ConfigManager with fallback methods."""
        
        def __init__(self, config_path: str = None):
            """Initialize with optional config path."""
            try:
                super().__init__(config_path)
            except:
                self.config_path = config_path or CONFIG_FILE
                logger.info(f"ConfigManager initialized with path: {self.config_path}")
        
        def load_config(self) -> Dict[str, Any]:
            """Load configuration from file."""
            try:
                return super().load_config()
            except:
                logger.warning("Falling back to manual config loading")
                try:
                    if os.path.exists(self.config_path):
                        with open(self.config_path, 'r') as f:
                            return json.load(f)
                    return {"sources": [], "schedule": "0 0 * * *", "enabled": False}
                except Exception as e:
                    logger.error(f"Error loading config: {str(e)}")
                    return {"error": "Failed to load config", "sources": []}
                
        def save_config(self, config: Dict[str, Any]) -> bool:
            """Save configuration to file."""
            try:
                return super().save_config(config)
            except:
                logger.warning("Falling back to manual config saving")
                try:
                    # Make sure config directory exists
                    os.makedirs(os.path.dirname(self.config_path), exist_ok=True)
                    with open(self.config_path, 'w') as f:
                        json.dump(config, f, indent=2)
                    return True
                except Exception as e:
                    logger.error(f"Error saving config: {str(e)}")
                    return False
                    
except ImportError:
    logger.warning("Could not import ConfigManager, using fallback implementation")
    
    class ConfigManager:
        """Fallback ConfigManager implementation."""
        
        def __init__(self, config_path: str = None):
            """Initialize with optional config path."""
            self.config_path = config_path or CONFIG_FILE
            logger.info(f"Fallback ConfigManager initialized with path: {self.config_path}")
            
        def load_config(self) -> Dict[str, Any]:
            """Load configuration from file."""
            logger.warning("Using fallback ConfigManager.load_config()")
            try:
                if os.path.exists(self.config_path):
                    with open(self.config_path, 'r') as f:
                        return json.load(f)
                return {"sources": [], "schedule": "0 0 * * *", "enabled": False}
            except Exception as e:
                logger.error(f"Error loading config: {str(e)}")
                return {"error": "Failed to load config", "sources": []}
                
        def save_config(self, config: Dict[str, Any]) -> bool:
            """Save configuration to file."""
            logger.warning("Using fallback ConfigManager.save_config()")
            try:
                # Make sure config directory exists
                os.makedirs(os.path.dirname(self.config_path), exist_ok=True)
                with open(self.config_path, 'w') as f:
                    json.dump(config, f, indent=2)
                return True
            except Exception as e:
                logger.error(f"Error saving config: {str(e)}")
                return False

try:
    # Try to import the actual ScraperManager
    from .scraper_manager import ScraperManager
except ImportError:
    logger.warning("Could not import ScraperManager, using fallback implementation")
    
    class ScraperManager:
        """Fallback ScraperManager implementation."""
        
        def __init__(self):
            """Initialize the scraper manager."""
            logger.info("Fallback ScraperManager initialized")
            
        async def start_scraping(self) -> bool:
            """Start the scraping process."""
            logger.warning("Using fallback ScraperManager.start_scraping()")
            global scrape_running, last_scrape_time
            if not scrape_running:
                scrape_running = True
                last_scrape_time = datetime.now().isoformat()
                return True
            return False
            
        async def stop_scraping(self) -> bool:
            """Stop the scraping process."""
            logger.warning("Using fallback ScraperManager.stop_scraping()")
            global scrape_running
            if scrape_running:
                scrape_running = False
                return True
            return False
            
        def is_running(self) -> bool:
            """Check if scraping is currently running."""
            logger.warning("Using fallback ScraperManager.is_running()")
            global scrape_running
            return scrape_running

# Singleton instances
_db_manager = None
_config_manager = None
_scraper_manager = None

def get_db_manager() -> DatabaseManager:
    """Get a singleton instance of DatabaseManager."""
    global _db_manager
    if _db_manager is None:
        _db_manager = DatabaseManager()
    return _db_manager

def get_config_manager() -> ConfigManager:
    """Get a singleton instance of ConfigManager."""
    global _config_manager
    if _config_manager is None:
        _config_manager = ConfigManager()
    return _config_manager

def get_scraper_manager() -> ScraperManager:
    """Get a singleton instance of ScraperManager."""
    global _scraper_manager
    if _scraper_manager is None:
        _scraper_manager = ScraperManager()
    return _scraper_manager

async def get_stats() -> Dict[str, Any]:
    """Get current scraping statistics."""
    try:
        db_manager = get_db_manager()
        scraper_manager = get_scraper_manager()
        
        job_count = await db_manager.get_job_count()
        recent_jobs = await db_manager.get_recent_jobs(5)
        
        return {
            "is_running": scraper_manager.is_running(),
            "last_scrape_time": last_scrape_time,
            "total_jobs": job_count,
            "recent_jobs": recent_jobs
        }
    except Exception as e:
        logger.exception("Error getting stats")
        return {
            "is_running": False,
            "error": str(e),
            "total_jobs": 0,
            "recent_jobs": []
        }

def read_log_file(limit: int = 100) -> List[str]:
    """Read the last N lines from the log file."""
    log_file = os.path.join(PROJECT_ROOT, "logs", "scraper.log")
    try:
        if os.path.exists(log_file):
            with open(log_file, 'r') as f:
                lines = f.readlines()
            return lines[-limit:] if lines else []
        return ["Log file not found"]
    except Exception as e:
        logger.exception("Error reading log file")
        return [f"Error reading log file: {str(e)}"]

async def get_logs(limit: int = 100) -> Dict[str, Any]:
    """Get recent logs with limit."""
    try:
        logs = read_log_file(limit)
        return {"logs": logs, "count": len(logs)}
    except Exception as e:
        logger.exception("Error getting logs")
        return {"logs": [f"Error: {str(e)}"], "count": 1, "error": True}

async def get_config() -> Dict[str, Any]:
    """Get current configuration."""
    try:
        config_manager = get_config_manager()
        return config_manager.load_config()
    except Exception as e:
        logger.exception("Error getting configuration")
        return {"error": str(e)}

async def update_config(new_config: Dict[str, Any]) -> Dict[str, bool]:
    """Update configuration."""
    try:
        config_manager = get_config_manager()
        success = config_manager.save_config(new_config)
        return {"success": success}
    except Exception as e:
        logger.exception("Error updating configuration")
        return {"success": False, "error": str(e)}

async def _run_scrape_job():
    """Run a scrape job asynchronously."""
    global scrape_running, last_scrape_time
    try:
        scraper_manager = get_scraper_manager()
        await scraper_manager.start_scraping()
        # Simulate scraping for fallback implementation
        await asyncio.sleep(10)
        # Mark as complete
        scrape_running = False
        last_scrape_time = datetime.now().isoformat()
    except Exception as e:
        logger.exception("Error during scrape job")
        scrape_running = False

async def start_scrape() -> Dict[str, bool]:
    """Start a manual scraping job."""
    global scrape_task, scrape_running
    try:
        if scrape_running:
            return {"success": False, "message": "Scrape already running"}
            
        scrape_running = True
        scrape_task = asyncio.create_task(_run_scrape_job())
        
        return {"success": True, "message": "Scrape started"}
    except Exception as e:
        logger.exception("Error starting scrape")
        scrape_running = False
        return {"success": False, "error": str(e)}

async def stop_scrape() -> Dict[str, bool]:
    """Stop the current scraping job."""
    global scrape_task, scrape_running
    try:
        if not scrape_running:
            return {"success": False, "message": "No scrape running"}
            
        scraper_manager = get_scraper_manager()
        await scraper_manager.stop_scraping()
        
        if scrape_task and not scrape_task.done():
            scrape_task.cancel()
            
        scrape_running = False
        return {"success": True, "message": "Scrape stopped"}
    except Exception as e:
        logger.exception("Error stopping scrape")
        scrape_running = False
        return {"success": False, "error": str(e)} 