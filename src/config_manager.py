import json
import logging
import os
import yaml
from datetime import datetime
from pathlib import Path
from typing import Dict, Any, Optional

from .log_setup import get_logger

# Central logger for ConfigManager
logger = get_logger("ConfigManager")


class ConfigManager:
    """
    Manages configuration and state for the job scraper.
    Loads from a YAML file and optionally merges environment variables.
    Also handles saving 'state' to allow resuming or tracking scraping progress.
    """

    def __init__(self, config_path: str = "config/api_config.yaml") -> None:
        """
        Initialize the config manager and load the YAML configuration.

        Args:
            config_path (str): Path to the YAML config file.
        """
        self.config_path: str = config_path
        # Immediately load config from YAML + any environment overrides
        self._load_config()

        # Setup the directory for storing persistent 'state' JSON
        self.state_dir = Path("job_data/state")
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.state_file = self.state_dir / "scraper_state.json"

    def _load_config(self) -> None:
        """
        Load configuration from the specified YAML file
        and parse it into class attributes (api_config, request_config, scraper_config, etc.).
        """
        try:
            with open(self.config_path, "r", encoding="utf-8") as f:
                config = yaml.safe_load(f)

            # Sections from YAML
            self.api_config: Dict[str, Any] = config.get("api", {})
            self.request_config: Dict[str, Any] = config.get("request", {})
            self.scraper_config: Dict[str, Any] = config.get("scraper", {})
            self.database_config: Dict[str, Any] = config.get("database", {})

            # Warn if critical sections are missing
            if not self.api_config:
                logger.warning("API configuration section is missing or empty")
            if not self.request_config:
                logger.warning("Request configuration is missing or empty")
            if not self.scraper_config:
                logger.warning("Scraper configuration is missing or empty")

            logger.info("Configuration loaded successfully from YAML")
        except FileNotFoundError:
            logger.error(f"Configuration file not found: {self.config_path}")
            raise
        except yaml.YAMLError as e:
            logger.error(f"Error parsing YAML: {str(e)}")
            raise
        except Exception as e:
            logger.error(f"Unexpected error loading configuration: {str(e)}")
            raise

    def load_state(self) -> Dict[str, Any]:
        """
        Load the latest scraper state from a JSON file, or return an empty dict if none exists.

        Returns:
            Dict[str, Any]: The loaded state dictionary.
        """
        if not self.state_file.exists():
            logger.info("No state file found. Starting fresh.")
            return {}
        try:
            with open(self.state_file, "r", encoding="utf-8") as f:
                state = json.load(f)
            logger.info(f"Loaded state from {self.state_file}")
            return state
        except json.JSONDecodeError as e:
            logger.error(f"Error parsing state file: {str(e)}")
            return {}
        except Exception as e:
            logger.error(f"Error loading state: {str(e)}")
            return {}

    def save_state(self, state_update: Dict[str, Any]) -> None:
        """
        Update and persist the scraper state with new values in JSON form.

        Args:
            state_update (Dict[str, Any]): Key-value pairs to update in the stored state.
        """
        try:
            current_state = self.load_state()
            current_state.update(state_update)

            # Always store a timestamp of the last update if not included
            if "last_updated" not in state_update:
                current_state["last_updated"] = datetime.now().isoformat()

            with open(self.state_file, "w", encoding="utf-8") as f:
                json.dump(current_state, f, indent=2, ensure_ascii=False)

            # Optionally create a backup if configured in 'state_tracking'
            backup_count = self.scraper_config.get("state_tracking", {}).get("backup_count", 3)
            if backup_count > 0:
                self._create_state_backup(backup_count)

            logger.debug("State updated successfully")
        except Exception as e:
            logger.error(f"Error saving state: {str(e)}")

    def _create_state_backup(self, backup_count: int) -> None:
        """
        Create a timestamped backup of the current state file, then remove older backups.

        Args:
            backup_count (int): Number of backups to keep.
        """
        try:
            timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            backup_file = self.state_dir / f"scraper_state_{timestamp}.json"

            if self.state_file.exists():
                with open(self.state_file, "r", encoding="utf-8") as src:
                    with open(backup_file, "w", encoding="utf-8") as dst:
                        dst.write(src.read())

            # Remove oldest backups if exceeding backup_count
            backups = sorted(self.state_dir.glob("scraper_state_*.json"))
            if len(backups) > backup_count:
                for old_backup in backups[:-backup_count]:
                    old_backup.unlink()
        except Exception as e:
            logger.error(f"Error creating state backup: {str(e)}")

    def should_save_files_with_db(self) -> bool:
        """
        Check if we should still save raw JSON/CSV/Parquet locally
        even when the database is enabled.

        Returns:
            bool: True if local file saving is desired alongside DB usage.
        """
        return self.database_config.get("save_raw_data", True)

    def get_db_connection_string(self) -> Optional[str]:
        """
        Return the database connection string if 'enabled' is True in the config.

        Returns:
            Optional[str]: Connection URI or None if the database is not enabled.
        """
        if self.database_config.get("enabled", False):
            return self.database_config.get("connection_string")
        return None

    def get_max_concurrent_requests(self) -> int:
        """
        Get the maximum number of concurrent HTTP requests allowed by the scraper.

        Returns:
            int: The concurrency limit (default 3 if missing).
        """
        return self.scraper_config.get('max_concurrent_requests', 3)

    def get_rate_limits(self) -> Dict[str, int]:
        """
        Get rate-limiting parameters from the config (requests_per_minute, burst).

        Returns:
            dict: Rate limit parameters.
        """
        rate_limit = self.scraper_config.get('rate_limit', {})
        return {
            'requests_per_minute': rate_limit.get('requests_per_minute', 60),
            'burst': rate_limit.get('burst', 5)
        }

    def get_retry_config(self) -> Dict[str, Any]:
        """
        Get retry-related parameters for controlling backoff logic.

        Returns:
            dict: Contains max_retries, min_delay, max_delay used for tenacity or similar.
        """
        return {
            'max_retries': self.scraper_config.get('max_retries', 5),
            'min_delay': self.scraper_config.get('retry_delay', {}).get('min', 2),
            'max_delay': self.scraper_config.get('retry_delay', {}).get('max', 10)
        }

    def get_monitoring_config(self) -> Dict[str, Any]:
        """
        Retrieve monitoring-related configuration if present.

        Returns:
            dict: A dictionary of monitoring settings (metrics, thresholds, etc.).
        """
        return self.scraper_config.get('monitoring', {})

    def update_config(self, section: str, key: str, value: Any) -> None:
        """
        Update a specific configuration value in the YAML file, then reload.

        Args:
            section (str): Name of the top-level config section (e.g. 'scraper', 'database').
            key (str): Key within that section.
            value (Any): New value to store.
        """
        try:
            with open(self.config_path, 'r', encoding='utf-8') as f:
                config = yaml.safe_load(f)

            if section not in config:
                config[section] = {}
            config[section][key] = value

            with open(self.config_path, 'w', encoding='utf-8') as f:
                yaml.dump(config, f, default_flow_style=False)

            # Reload the config into memory
            self._load_config()
            logger.info(f"Updated config: {section}.{key} = {value}")

        except Exception as e:
            logger.error(f"Error updating config: {str(e)}")

    def update_scraper_config(self, new_config: Dict[str, Any]) -> bool:
        """
        Update the entire scraper configuration section with new values.
        
        Args:
            new_config (Dict[str, Any]): New scraper configuration dictionary
            
        Returns:
            bool: True if update was successful, False otherwise
        """
        try:
            # Validate essential configuration parameters
            for required_key in ['max_pages', 'batch_size']:
                if required_key not in new_config:
                    logger.warning(f"Required scraper config key missing: {required_key}")
                    return False
            
            # Update timestamp
            new_config['last_updated'] = datetime.now().isoformat()
            
            # Load current full config
            with open(self.config_path, 'r', encoding='utf-8') as f:
                config = yaml.safe_load(f)
            
            # Update scraper section
            config['scraper'] = new_config
            
            # Write updated config back to file
            with open(self.config_path, 'w', encoding='utf-8') as f:
                yaml.dump(config, f, default_flow_style=False)
            
            # Reload config to ensure changes are in memory
            self._load_config()
            
            logger.info("Scraper configuration updated successfully")
            return True
            
        except Exception as e:
            logger.error(f"Error updating scraper configuration: {str(e)}")
            return False
