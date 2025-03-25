"""
Redis Cache Utility for Job Scraper Application

This module provides a Redis-based caching system for the job scraper application,
with support for serialization, TTL, and batch operations.
"""

import json
import pickle
import hashlib
import logging
from datetime import timedelta
from typing import Any, Dict, List, Optional, Tuple, Union, Callable

import redis
from redis.exceptions import RedisError

from app.utils.config import get_config


logger = logging.getLogger(__name__)


class RedisCache:
    """Redis-based cache implementation for the job scraper application.
    
    This class provides methods for storing and retrieving data from Redis,
    with support for serialization, time-to-live (TTL), and namespacing.
    """
    
    def __init__(self, namespace: str = "job_scraper"):
        """Initialize the Redis cache.
        
        Args:
            namespace: Namespace prefix for all cache keys
        """
        config = get_config()
        redis_config = config.get('redis', {})
        
        self.namespace = namespace
        self.default_ttl = redis_config.get('default_ttl', 3600)  # 1 hour
        
        # Connect to Redis
        try:
            if 'url' in redis_config:
                self.client = redis.from_url(redis_config['url'])
            else:
                self.client = redis.Redis(
                    host=redis_config.get('host', 'localhost'),
                    port=redis_config.get('port', 6379),
                    db=redis_config.get('db', 0),
                    password=redis_config.get('password'),
                    ssl=redis_config.get('ssl', False),
                    decode_responses=False  # We'll handle decoding ourselves
                )
            # Test connection
            self.client.ping()
            logger.info(f"Connected to Redis cache at {redis_config.get('host', 'localhost')}:{redis_config.get('port', 6379)}")
        except RedisError as e:
            logger.warning(f"Failed to connect to Redis: {e}")
            self.client = None
    
    def _get_key(self, key: str) -> str:
        """Get the fully qualified key with namespace.
        
        Args:
            key: The base key
            
        Returns:
            Fully qualified key with namespace
        """
        return f"{self.namespace}:{key}"
    
    def _hash_key(self, data: Any) -> str:
        """Create a hash key from complex data.
        
        Args:
            data: The data to hash (can be any serializable object)
            
        Returns:
            MD5 hash of the serialized data
        """
        if isinstance(data, (str, int, float, bool)):
            serialized = str(data).encode('utf-8')
        else:
            serialized = json.dumps(data, sort_keys=True).encode('utf-8')
        
        return hashlib.md5(serialized).hexdigest()
    
    def is_available(self) -> bool:
        """Check if Redis cache is available.
        
        Returns:
            True if the cache is available, False otherwise
        """
        if not self.client:
            return False
        
        try:
            return self.client.ping()
        except RedisError:
            return False
    
    def get(self, key: str, default: Any = None) -> Any:
        """Get a value from the cache.
        
        Args:
            key: The cache key
            default: Default value to return if key not found
            
        Returns:
            The cached value or default if not found
        """
        if not self.is_available():
            return default
        
        try:
            full_key = self._get_key(key)
            data = self.client.get(full_key)
            
            if data is None:
                return default
            
            return pickle.loads(data)
        except (RedisError, pickle.PickleError) as e:
            logger.warning(f"Error retrieving from cache: {e}")
            return default
    
    def set(self, key: str, value: Any, ttl: Optional[int] = None) -> bool:
        """Set a value in the cache.
        
        Args:
            key: The cache key
            value: The value to cache
            ttl: Time-to-live in seconds (None for default, 0 for no expiration)
            
        Returns:
            True if successful, False otherwise
        """
        if not self.is_available():
            return False
        
        try:
            full_key = self._get_key(key)
            serialized = pickle.dumps(value)
            
            if ttl is None:
                ttl = self.default_ttl
            
            if ttl > 0:
                return bool(self.client.setex(full_key, ttl, serialized))
            else:
                return bool(self.client.set(full_key, serialized))
        except (RedisError, pickle.PickleError) as e:
            logger.warning(f"Error setting cache: {e}")
            return False
    
    def delete(self, key: str) -> bool:
        """Delete a value from the cache.
        
        Args:
            key: The cache key
            
        Returns:
            True if deleted, False otherwise
        """
        if not self.is_available():
            return False
        
        try:
            full_key = self._get_key(key)
            return bool(self.client.delete(full_key))
        except RedisError as e:
            logger.warning(f"Error deleting from cache: {e}")
            return False
    
    def exists(self, key: str) -> bool:
        """Check if a key exists in the cache.
        
        Args:
            key: The cache key
            
        Returns:
            True if the key exists, False otherwise
        """
        if not self.is_available():
            return False
        
        try:
            full_key = self._get_key(key)
            return bool(self.client.exists(full_key))
        except RedisError as e:
            logger.warning(f"Error checking cache existence: {e}")
            return False
    
    def clear_namespace(self) -> bool:
        """Clear all keys in the current namespace.
        
        Returns:
            True if successful, False otherwise
        """
        if not self.is_available():
            return False
        
        try:
            pattern = f"{self.namespace}:*"
            cursor = 0
            
            while True:
                cursor, keys = self.client.scan(cursor, pattern, 100)
                if keys:
                    self.client.delete(*keys)
                
                if cursor == 0:
                    break
            
            return True
        except RedisError as e:
            logger.warning(f"Error clearing namespace: {e}")
            return False
    
    def mget(self, keys: List[str], default: Any = None) -> List[Any]:
        """Get multiple values from the cache.
        
        Args:
            keys: List of cache keys
            default: Default value to return for missing keys
            
        Returns:
            List of cached values (or default for missing keys)
        """
        if not self.is_available() or not keys:
            return [default] * len(keys)
        
        try:
            full_keys = [self._get_key(key) for key in keys]
            values = self.client.mget(full_keys)
            
            result = []
            for value in values:
                if value is None:
                    result.append(default)
                else:
                    try:
                        result.append(pickle.loads(value))
                    except pickle.PickleError:
                        result.append(default)
            
            return result
        except RedisError as e:
            logger.warning(f"Error retrieving multiple keys from cache: {e}")
            return [default] * len(keys)
    
    def mset(self, mapping: Dict[str, Any], ttl: Optional[int] = None) -> bool:
        """Set multiple values in the cache.
        
        Args:
            mapping: Dictionary of key-value pairs to cache
            ttl: Time-to-live in seconds (None for default, 0 for no expiration)
            
        Returns:
            True if successful, False otherwise
        """
        if not self.is_available() or not mapping:
            return False
        
        try:
            serialized_mapping = {}
            for key, value in mapping.items():
                full_key = self._get_key(key)
                serialized_mapping[full_key] = pickle.dumps(value)
            
            # Use pipeline for better performance
            with self.client.pipeline() as pipe:
                pipe.mset(serialized_mapping)
                
                if ttl is not None and ttl > 0:
                    for full_key in serialized_mapping.keys():
                        pipe.expire(full_key, ttl)
                
                pipe.execute()
            
            return True
        except (RedisError, pickle.PickleError) as e:
            logger.warning(f"Error setting multiple keys in cache: {e}")
            return False
    
    def increment(self, key: str, amount: int = 1) -> Optional[int]:
        """Increment a counter in the cache.
        
        Args:
            key: The cache key
            amount: Amount to increment by
            
        Returns:
            New value or None if failed
        """
        if not self.is_available():
            return None
        
        try:
            full_key = self._get_key(key)
            return self.client.incrby(full_key, amount)
        except RedisError as e:
            logger.warning(f"Error incrementing cache key: {e}")
            return None
    
    def cached(self, key_pattern: str = None, ttl: Optional[int] = None) -> Callable:
        """Decorator to cache function results.
        
        Args:
            key_pattern: Pattern for cache key format (use {} for function arguments)
            ttl: Time-to-live in seconds
            
        Returns:
            Decorator function
        """
        def decorator(func):
            def wrapper(*args, **kwargs):
                # Generate cache key
                if key_pattern:
                    if '{}' in key_pattern:
                        # Use args and kwargs to format the key
                        all_args = list(args)
                        all_args.extend(kwargs.values())
                        key = key_pattern.format(*all_args)
                    else:
                        # Use the key pattern as is
                        key = key_pattern
                else:
                    # Generate a key based on function name and arguments
                    arg_hash = self._hash_key((args, kwargs))
                    key = f"{func.__name__}:{arg_hash}"
                
                # Check cache
                cached_result = self.get(key)
                if cached_result is not None:
                    return cached_result
                
                # Call function and cache result
                result = func(*args, **kwargs)
                self.set(key, result, ttl)
                return result
            
            return wrapper
        
        return decorator


# Create a singleton instance
redis_cache = RedisCache()


def get_cache() -> RedisCache:
    """Get the cache instance.
    
    Returns:
        RedisCache instance
    """
    return redis_cache 