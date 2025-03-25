"""
Exception hierarchy for the Job Scraper application.

This module defines a consistent exception hierarchy for all
parts of the application to use, enabling better error handling
and more informative error messages.
"""
from typing import Optional, Any


class JobScraperError(Exception):
    """Base exception for all job scraper errors."""
    
    def __init__(self, message: str, details: Optional[Any] = None) -> None:
        """
        Initialize the exception.
        
        Args:
            message: Human-readable error message
            details: Additional error details (can be any type)
        """
        self.message = message
        self.details = details
        super().__init__(message)


class ScraperConnectionError(JobScraperError):
    """Exception raised for scraper connection issues."""
    pass


class ScraperParsingError(JobScraperError):
    """Exception raised for issues parsing scraped data."""
    pass


class DatabaseError(JobScraperError):
    """Exception raised for database issues."""
    pass


class ConfigurationError(JobScraperError):
    """Exception raised for configuration issues."""
    pass


class ValidationError(JobScraperError):
    """Exception raised for data validation issues."""
    pass


class ImportExportError(JobScraperError):
    """Exception raised for import/export issues."""
    pass


class AuthenticationError(JobScraperError):
    """Exception raised for authentication issues."""
    pass


class RateLimitError(JobScraperError):
    """Exception raised when rate limits are exceeded."""
    pass


class ResourceNotFoundError(JobScraperError):
    """Exception raised when a requested resource is not found."""
    pass 