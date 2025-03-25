"""
Template filters for the Job Scraper application.

This module provides custom filters for Jinja2 templates,
such as date formatting, number formatting, etc.
"""

import datetime
from typing import Optional, Union
from flask import Flask


def register_filters(app: Flask) -> None:
    """
    Register all template filters with the Flask application.
    
    Args:
        app: Flask application instance
    """
    app.add_template_filter(format_datetime)
    app.add_template_filter(format_relative_time)
    app.add_template_filter(format_currency)
    app.add_template_filter(pluralize)
    app.add_template_filter(format_filesize)


def format_datetime(value: Optional[Union[str, datetime.datetime]], format_str: str = '%B %d, %Y') -> str:
    """
    Format a datetime object or string as a readable date string.
    
    Args:
        value: Datetime object or string to format
        format_str: Format string to use
        
    Returns:
        Formatted date string
    """
    if value is None:
        return ''
    
    if isinstance(value, str):
        try:
            value = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
        except (ValueError, AttributeError):
            return value
    
    if isinstance(value, datetime.datetime):
        return value.strftime(format_str)
    
    return str(value)


def format_relative_time(value: Optional[Union[str, datetime.datetime]]) -> str:
    """
    Format a datetime object or string as a relative time string (e.g., "2 hours ago").
    
    Args:
        value: Datetime object or string to format
        
    Returns:
        Relative time string
    """
    if value is None:
        return ''
    
    if isinstance(value, str):
        try:
            value = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
        except (ValueError, AttributeError):
            return value
    
    if not isinstance(value, datetime.datetime):
        return str(value)
    
    now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    diff = now - value
    
    if diff.days < 0:
        return 'in the future'
    
    if diff.days == 0:
        if diff.seconds < 60:
            return 'just now'
        if diff.seconds < 3600:
            minutes = diff.seconds // 60
            return f'{minutes} minute{"s" if minutes != 1 else ""} ago'
        else:
            hours = diff.seconds // 3600
            return f'{hours} hour{"s" if hours != 1 else ""} ago'
    
    if diff.days == 1:
        return 'yesterday'
    
    if diff.days < 7:
        return f'{diff.days} days ago'
    
    if diff.days < 30:
        weeks = diff.days // 7
        return f'{weeks} week{"s" if weeks != 1 else ""} ago'
    
    if diff.days < 365:
        months = diff.days // 30
        return f'{months} month{"s" if months != 1 else ""} ago'
    
    years = diff.days // 365
    return f'{years} year{"s" if years != 1 else ""} ago'


def format_currency(value: Optional[Union[str, int, float]], currency: str = "$") -> str:
    """
    Format a number as currency.
    
    Args:
        value: Number to format
        currency: Currency symbol to use
        
    Returns:
        Formatted currency string
    """
    if value is None:
        return ''
    
    try:
        # Convert to float if it's a string
        if isinstance(value, str):
            value = float(value)
        
        # Format the number with commas and 2 decimal places
        return f"{currency}{value:,.2f}"
    except (ValueError, TypeError):
        return str(value)


def pluralize(count: int, singular: str, plural: Optional[str] = None) -> str:
    """
    Return singular or plural form of a word based on count.
    
    Args:
        count: Count to determine plurality
        singular: Singular form of the word
        plural: Plural form of the word (if None, adds 's' to singular)
        
    Returns:
        Appropriate form of the word based on count
    """
    if count == 1:
        return singular
    else:
        return plural or f"{singular}s"


def format_filesize(bytes: int) -> str:
    """
    Format file size in human-readable form.
    
    Args:
        bytes: Size in bytes
        
    Returns:
        Human-readable file size string
    """
    # Convert bytes to KB, MB, GB, etc.
    units = ['B', 'KB', 'MB', 'GB', 'TB']
    size = float(bytes)
    unit_index = 0
    
    while size >= 1024 and unit_index < len(units) - 1:
        size /= 1024
        unit_index += 1
    
    return f"{size:.1f} {units[unit_index]}" 