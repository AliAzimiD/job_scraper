from datetime import datetime, timedelta
from typing import Optional, Union
import dateparser

def register_filters(app):
    """
    Register custom template filters with the Flask app.
    
    Args:
        app: Flask application object
    """
    app.template_filter('datetime')(format_datetime)
    app.template_filter('relative_time')(format_relative_time)
    app.template_filter('currency')(format_currency)
    app.template_filter('pluralize')(pluralize)

def format_datetime(value: Optional[Union[str, datetime]], format_str: str = '%B %d, %Y') -> str:
    """
    Format a datetime object or string as a readable date string.
    
    Args:
        value: Date string or datetime object
        format_str: Format string for the output
        
    Returns:
        Formatted date string
    """
    if value is None:
        return "N/A"
        
    if isinstance(value, str):
        try:
            # Try to parse the string into a datetime
            parsed_date = dateparser.parse(value)
            if parsed_date is None:
                return value
            value = parsed_date
        except Exception:
            return value
    
    if isinstance(value, datetime):
        return value.strftime(format_str)
    
    return str(value)

def format_relative_time(value: Optional[Union[str, datetime]]) -> str:
    """
    Format a datetime as a relative time string (e.g., "3 days ago")
    
    Args:
        value: Date string or datetime object
        
    Returns:
        Relative time string
    """
    if value is None:
        return "N/A"
        
    # Convert string to datetime if needed
    if isinstance(value, str):
        try:
            parsed_date = dateparser.parse(value)
            if parsed_date is None:
                return value
            value = parsed_date
        except Exception:
            return value
    
    if not isinstance(value, datetime):
        return str(value)
    
    now = datetime.now()
    diff = now - value
    
    # Future date
    if diff.total_seconds() < 0:
        return f"in the future"
    
    # Past date
    seconds = diff.total_seconds()
    
    if seconds < 60:
        return f"just now"
    elif seconds < 3600:
        minutes = int(seconds // 60)
        return f"{minutes} minute{'s' if minutes != 1 else ''} ago"
    elif seconds < 86400:
        hours = int(seconds // 3600)
        return f"{hours} hour{'s' if hours != 1 else ''} ago"
    elif seconds < 604800:
        days = int(seconds // 86400)
        return f"{days} day{'s' if days != 1 else ''} ago"
    elif seconds < 2419200:
        weeks = int(seconds // 604800)
        return f"{weeks} week{'s' if weeks != 1 else ''} ago"
    elif seconds < 29030400:
        months = int(seconds // 2419200)
        return f"{months} month{'s' if months != 1 else ''} ago"
    else:
        years = int(seconds // 29030400)
        return f"{years} year{'s' if years != 1 else ''} ago"

def format_currency(value: Optional[Union[str, int, float]], currency: str = "$") -> str:
    """
    Format a number as currency
    
    Args:
        value: Number to format
        currency: Currency symbol
        
    Returns:
        Formatted currency string
    """
    if value is None:
        return "N/A"
    
    try:
        # Try to convert to float
        if isinstance(value, str):
            value = float(value.replace(',', ''))
        else:
            value = float(value)
        
        # Format with thousands separator and 2 decimal places
        return f"{currency}{value:,.2f}"
    except (ValueError, TypeError):
        return str(value)

def pluralize(count: int, singular: str, plural: Optional[str] = None) -> str:
    """
    Return singular or plural form based on count
    
    Args:
        count: Number of items
        singular: Singular form
        plural: Plural form (if None, adds 's' to singular)
        
    Returns:
        Appropriate form based on count
    """
    if count == 1:
        return f"{count} {singular}"
    else:
        plural_form = plural if plural is not None else f"{singular}s"
        return f"{count} {plural_form}" 