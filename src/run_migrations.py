"""
Database migration runner script.

This script runs database migrations to update the schema.
It can be run manually or as part of container startup.
"""

import os
import sys
import logging
import asyncio
import time
from pathlib import Path
from typing import List, Optional

import asyncpg

# Set up logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[logging.StreamHandler()],
)
logger = logging.getLogger("db_migrations")


class MigrationRunner:
    """Handles database schema migrations."""

    def __init__(self, conn_string: Optional[str] = None) -> None:
        """
        Initialize the migration runner.
        
        Args:
            conn_string: PostgreSQL connection string, or None to build from env vars
        """
        self.conn_string = conn_string or self._build_conn_string()
        self.conn: Optional[asyncpg.Connection] = None
        self.schema = "public"
        self.migration_dir = Path(__file__).parent.parent / "migrations"

    def _build_conn_string(self) -> str:
        """Build connection string from environment variables."""
        db_user = os.getenv("POSTGRES_USER", "postgres")
        db_password = os.getenv("POSTGRES_PASSWORD", "")
        db_host = os.getenv("POSTGRES_HOST", "localhost")
        db_port = os.getenv("POSTGRES_PORT", "5432")
        db_name = os.getenv("POSTGRES_DB", "jobsdb")

        # If password is in a file, read it
        pw_file = os.getenv("POSTGRES_PASSWORD_FILE")
        if pw_file and os.path.exists(pw_file):
            with open(pw_file, "r", encoding="utf-8") as pf:
                db_password = pf.read().strip()

        return f"postgresql://{db_user}:{db_password}@{db_host}:{db_port}/{db_name}"

    async def connect(self) -> bool:
        """
        Connect to the database.
        
        Returns:
            bool: True if connection was successful
        """
        try:
            self.conn = await asyncpg.connect(self.conn_string)
            version = await self.conn.fetchval("SELECT version()")
            logger.info(f"Connected to database: {version}")
            return True
        except Exception as e:
            logger.error(f"Error connecting to database: {str(e)}")
            return False

    async def check_schema_version(self) -> int:
        """
        Check current schema version.
        
        Returns:
            int: Current schema version or 0 if not initialized
        """
        if not self.conn:
            logger.error("Not connected to database")
            return 0
            
        try:
            # Check if schema_version table exists
            schema_version_exists = await self.conn.fetchval(
                f"""
                SELECT EXISTS (
                    SELECT FROM information_schema.tables 
                    WHERE table_schema = '{self.schema}' 
                    AND table_name = 'schema_version'
                )
                """
            )
            
            if not schema_version_exists:
                # Create schema version table
                await self.conn.execute(
                    f"""
                    CREATE TABLE IF NOT EXISTS {self.schema}.schema_version (
                        id SERIAL PRIMARY KEY,
                        version INTEGER NOT NULL,
                        description TEXT,
                        applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
                    )
                    """
                )
                
                # Insert initial version
                await self.conn.execute(
                    f"""
                    INSERT INTO {self.schema}.schema_version (version, description)
                    VALUES (1, 'Initial schema creation')
                    """
                )
                return 1
            
            # Get current schema version
            current_version = await self.conn.fetchval(
                f"SELECT MAX(version) FROM {self.schema}.schema_version"
            )
            return current_version or 0
            
        except Exception as e:
            logger.error(f"Error checking schema version: {str(e)}")
            return 0

    async def run_migrations(self, target_version: Optional[int] = None) -> bool:
        """
        Run migrations up to target version or latest.
        
        Args:
            target_version: Target schema version or None for latest
            
        Returns:
            bool: True if migrations were successful
        """
        if not self.conn:
            logger.error("Not connected to database")
            return False
            
        current_version = await self.check_schema_version()
        logger.info(f"Current schema version: {current_version}")
        
        # If target version is not specified, use environment variable
        if target_version is None:
            env_version = os.getenv("DB_SCHEMA_VERSION")
            if env_version and env_version.isdigit():
                target_version = int(env_version)
            else:
                # Default to version 2 (our normalized schema)
                target_version = 2
                
        logger.info(f"Target schema version: {target_version}")
        
        if current_version >= target_version:
            logger.info("Database schema is already at or above target version")
            return True
            
        # Find migration files
        migration_files = [
            f for f in sorted(self.migration_dir.glob("*.sql"))
            if f.name.startswith(("0", "1", "2", "3", "4", "5", "6", "7", "8", "9"))
        ]
        
        if not migration_files:
            logger.warning("No migration files found")
            return False
            
        logger.info(f"Found {len(migration_files)} migration files")
        
        try:
            # Start transaction
            async with self.conn.transaction():
                # Apply migrations in order
                for migration_file in migration_files:
                    logger.info(f"Applying migration: {migration_file.name}")
                    
                    with open(migration_file, 'r', encoding='utf-8') as f:
                        migration_sql = f.read()
                        await self.conn.execute(migration_sql)
                        
                # Update schema version
                await self.conn.execute(
                    f"""
                    INSERT INTO {self.schema}.schema_version (version, description)
                    VALUES ($1, $2)
                    """,
                    target_version,
                    f"Migration to version {target_version}"
                )
                
            logger.info(f"Successfully migrated database to version {target_version}")
            return True
            
        except Exception as e:
            logger.error(f"Error applying migrations: {str(e)}")
            return False

    async def close(self) -> None:
        """Close database connection."""
        if self.conn:
            await self.conn.close()
            logger.info("Database connection closed")


async def main() -> int:
    """
    Main entry point for the migration runner.
    
    Returns:
        int: Exit code (0 for success, 1 for failure)
    """
    logger.info("Starting database migration runner")
    
    # Get target version from command line or environment
    target_version = None
    if len(sys.argv) > 1 and sys.argv[1].isdigit():
        target_version = int(sys.argv[1])
    
    runner = MigrationRunner()
    
    try:
        # Connect to database
        connected = await runner.connect()
        if not connected:
            logger.error("Failed to connect to database")
            return 1
            
        # Run migrations
        success = await runner.run_migrations(target_version)
        
        # Close connection
        await runner.close()
        
        if success:
            logger.info("Migrations completed successfully")
            return 0
        else:
            logger.error("Migrations failed")
            return 1
            
    except Exception as e:
        logger.error(f"Error during migration: {str(e)}")
        if runner.conn:
            await runner.close()
        return 1


if __name__ == "__main__":
    # Run the async main function
    exit_code = asyncio.run(main())
    sys.exit(exit_code) 