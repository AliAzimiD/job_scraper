import os
import logging
import contextlib
from typing import Dict, Any, List, Optional, Tuple, Union
from pathlib import Path

import psycopg2
import psycopg2.pool
import psycopg2.extras
from psycopg2.extensions import connection, cursor

from ..log_setup import get_logger

# Get logger instance
logger = get_logger("db_service")


class DatabaseService:
    """
    Manages database connections and operations with connection pooling.
    Uses context managers for automatic resource cleanup.
    """
    
    def __init__(
        self, 
        connection_string: Optional[str] = None,
        min_connections: int = 5,
        max_connections: int = 20,
        schema: str = "public"
    ) -> None:
        """
        Initialize the database service.
        
        Args:
            connection_string: Database connection string
            min_connections: Minimum number of connections in the pool
            max_connections: Maximum number of connections in the pool
            schema: Database schema to use
        """
        self.schema = schema
        
        # Get connection parameters
        if connection_string:
            self.connection_string = connection_string
        else:
            self.connection_string = self._build_connection_string()
            
        # Initialize connection pool
        try:
            self.pool = psycopg2.pool.ThreadedConnectionPool(
                minconn=min_connections,
                maxconn=max_connections,
                dsn=self.connection_string
            )
            logger.info(f"Database connection pool initialized with {min_connections}-{max_connections} connections")
        except Exception as e:
            logger.error(f"Failed to initialize connection pool: {e}")
            raise
    
    def _build_connection_string(self) -> str:
        """Build database connection string from environment variables."""
        host = os.environ.get("POSTGRES_HOST", "localhost")
        port = os.environ.get("POSTGRES_PORT", "5432")
        db = os.environ.get("POSTGRES_DB", "jobsdb")
        user = os.environ.get("POSTGRES_USER", "jobuser")
        
        # Try to get password from file first, then from environment
        password_file = os.environ.get("POSTGRES_PASSWORD_FILE")
        if password_file and Path(password_file).exists():
            with open(password_file, 'r') as f:
                password = f.read().strip()
        else:
            password = os.environ.get("POSTGRES_PASSWORD", "devpassword")
        
        return f"postgresql://{user}:{password}@{host}:{port}/{db}"
    
    @contextlib.contextmanager
    def get_connection(self) -> connection:
        """
        Get a connection from the pool and ensure it's closed properly.
        
        Returns:
            Database connection object
        """
        conn = None
        try:
            conn = self.pool.getconn()
            yield conn
        except Exception as e:
            logger.error(f"Error getting connection from pool: {e}")
            raise
        finally:
            if conn:
                self.pool.putconn(conn)
    
    @contextlib.contextmanager
    def get_cursor(self, cursor_factory=None) -> cursor:
        """
        Get a cursor from a pooled connection and ensure it's closed properly.
        
        Args:
            cursor_factory: Optional cursor factory to use (e.g. DictCursor)
            
        Returns:
            Database cursor object
        """
        with self.get_connection() as conn:
            cursor = None
            try:
                if cursor_factory:
                    cursor = conn.cursor(cursor_factory=cursor_factory)
                else:
                    cursor = conn.cursor()
                yield cursor
            except Exception as e:
                logger.error(f"Error creating cursor: {e}")
                conn.rollback()
                raise
            finally:
                if cursor:
                    cursor.close()
    
    def execute_query(
        self, 
        query: str, 
        params: Optional[Tuple] = None,
        fetch: bool = False,
        fetch_one: bool = False,
        commit: bool = True,
        dict_cursor: bool = False
    ) -> Optional[List[Dict[str, Any]]]:
        """
        Execute a query with proper error handling and connection management.
        
        Args:
            query: SQL query to execute
            params: Query parameters
            fetch: Whether to fetch results
            fetch_one: Whether to fetch a single result
            commit: Whether to commit the transaction
            dict_cursor: Whether to use a dictionary cursor
            
        Returns:
            Query results if fetch=True, otherwise None
        """
        cursor_factory = psycopg2.extras.DictCursor if dict_cursor else None
        
        with self.get_connection() as conn:
            with conn.cursor(cursor_factory=cursor_factory) as cur:
                try:
                    # Execute the query
                    cur.execute(query, params)
                    
                    # Fetch results if requested
                    result = None
                    if fetch_one:
                        result = cur.fetchone()
                        if dict_cursor and result:
                            result = dict(result)
                    elif fetch:
                        result = cur.fetchall()
                        if dict_cursor and result:
                            result = [dict(row) for row in result]
                    
                    # Commit if requested
                    if commit:
                        conn.commit()
                    
                    return result
                except Exception as e:
                    conn.rollback()
                    logger.error(f"Query execution error: {e}, Query: {query}")
                    raise
    
    def close(self) -> None:
        """Close the connection pool and release all resources."""
        if hasattr(self, 'pool'):
            self.pool.closeall()
            logger.info("Database connection pool closed")


# Global instance for reuse
_db_service_instance = None

def get_db_service() -> DatabaseService:
    """
    Get or create a singleton instance of the database service.
    
    Returns:
        DatabaseService instance
    """
    global _db_service_instance
    
    if _db_service_instance is None:
        # Get connection pool parameters from environment
        min_connections = int(os.environ.get("DB_MIN_CONNECTIONS", "5"))
        max_connections = int(os.environ.get("DB_MAX_CONNECTIONS", "20"))
        schema = os.environ.get("DB_SCHEMA", "public")
        
        # Create service instance
        _db_service_instance = DatabaseService(
            min_connections=min_connections,
            max_connections=max_connections,
            schema=schema
        )
    
    return _db_service_instance 