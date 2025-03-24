import asyncio

import logging
import json
import time
import traceback
from datetime import datetime
from typing import Dict, List, Any, Optional, Union, Tuple

import asyncpg
import pandas as pd
from sqlalchemy import create_engine
from sqlalchemy.orm import declarative_base
from tenacity import retry, stop_after_attempt, wait_exponential, retry_if_exception_type

from .log_setup import get_logger

# Declare a base for any ORM models if needed - using new SQLAlchemy API
Base = declarative_base()

# Create a logger specifically for the DatabaseManager.
logger = get_logger("DatabaseManager")


class DatabaseManager:
    """
    Manages database operations for the job scraper,
    including initializing connections, creating tables,
    and upserting job data in bulk.
    """

    def __init__(
        self,
        connection_string: str,
        schema: str = "public",
        batch_size: int = 1000,
        min_conn: int = 5,
        max_conn: int = 20,
        max_retries: int = 3,
        retry_interval: float = 1.0
    ) -> None:
        """
        Initialize the database manager with connection details and pooling settings.

        Args:
            connection_string (str): PostgreSQL connection URI.
            schema (str): DB schema. Defaults to "public".
            batch_size (int): Max chunk size for inserts. Defaults to 1000.
            min_conn (int): Minimum number of connections in the pool.
            max_conn (int): Maximum number of connections in the pool.
            max_retries (int): Maximum number of retries for operations.
            retry_interval (float): Base retry interval in seconds.
        """
        self.connection_string: str = connection_string
        self._schema: str = schema  # Store as protected variable
        self.batch_size: int = batch_size
        self.min_conn: int = min_conn
        self.max_conn: int = max_conn
        self.max_retries: int = max_retries
        self.retry_interval: float = retry_interval
        self.engine = None  # Will hold a SQLAlchemy engine if needed.
        self.pool: Optional[asyncpg.pool.Pool] = None
        self.is_connected: bool = False
        self.last_connection_check: float = 0
        self.connection_check_interval: float = 60.0  # Check connection every 60 seconds

        # Optional metrics tracking.
        self.metrics: Dict[str, Union[int, float]] = {
            "total_jobs_inserted": 0,
            "total_jobs_updated": 0,
            "total_batches": 0,
            "failed_operations": 0,
            "avg_insertion_time": 0.0,
            "connection_errors": 0,
            "connection_retries": 0,
            "successful_retries": 0
        }

    @property
    def schema(self) -> str:
        """The database schema to use."""
        return self._schema

    async def initialize(self) -> bool:
        """
        Initialize database connections and create required tables.

        Returns:
            bool: True if successful, False otherwise.
        """
        try:
            # Create an optional SQLAlchemy engine (useful for schema tasks).
            self.engine = create_engine(self.connection_string)

            # Parse the connection string for asyncpg and create a connection pool.
            conn_params = self._parse_connection_string(self.connection_string)
            
            # Create a connection pool with proper min/max connections
            self.pool = await asyncpg.create_pool(
                min_size=self.min_conn,
                max_size=self.max_conn,
                command_timeout=30.0,
                **conn_params
            )

            # Test the connection by fetching the version and creating tables.
            async with self.pool.acquire() as conn:
                version = await conn.fetchval("SELECT version()")
                logger.info(f"Connected to database: {version}")
                await self._create_tables()

            self.is_connected = True
            self.last_connection_check = time.time()
            logger.info(f"Database connection established with pool size {self.min_conn}-{self.max_conn}")
            return True

        except Exception as e:
            logger.error(f"Failed to initialize database: {str(e)}")
            logger.error(traceback.format_exc())
            return False

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=4, max=10),
        retry=retry_if_exception_type((asyncpg.exceptions.ConnectionDoesNotExistError, 
                                        asyncpg.exceptions.InterfaceError))
    )
    async def _check_connection(self) -> bool:
        """
        Verify the database connection is still valid, with retries.
        
        Returns:
            bool: True if connection is valid
        """
        if not self.pool:
            return False
            
        try:
            async with self.pool.acquire() as conn:
                await conn.fetchval("SELECT 1")
            return True
        except (asyncpg.exceptions.PostgresError, asyncpg.exceptions.InterfaceError) as e:
            logger.warning(f"Connection check failed: {str(e)}")
            raise  # Let retry handle this

    async def ensure_connection(self) -> bool:
        """
        Ensure database connection is active and reconnect if needed.
        Should be called before any major database operation.
        
        Returns:
            bool: True if connection is ready to use
        """
        # Skip frequent checks
        current_time = time.time()
        if (current_time - self.last_connection_check < self.connection_check_interval and 
            self.is_connected):
            return True
            
        # Check connection status
        try:
            if not self.pool or not self.is_connected:
                logger.info("Connection pool not initialized or marked as disconnected, reconnecting...")
                self.is_connected = await self.initialize()
                return self.is_connected
                
            # Test the connection
            connection_valid = await self._check_connection()
            self.last_connection_check = current_time
            return connection_valid
            
        except Exception as e:
            logger.error(f"Connection error: {str(e)}")
            self.metrics["connection_errors"] += 1
            self.is_connected = False
            return False

    def _parse_connection_string(self, conn_string: str) -> Dict[str, Union[str, int]]:
        """
        Convert a PostgreSQL connection URI into parameters for asyncpg.

        Args:
            conn_string (str): PostgreSQL URI (e.g., postgresql://user:pass@host:port/dbname).

        Returns:
            Dict[str, Union[str, int]]: Connection parameters.
        """
        temp = conn_string
        if temp.startswith("postgresql://"):
            temp = temp.replace("postgresql://", "")
        elif temp.startswith("postgresql+psycopg2://"):
            temp = temp.replace("postgresql+psycopg2://", "")

        auth, rest = temp.split("@", 1)
        host_port, database = rest.split("/", 1)

        if ":" in auth:
            user, password = auth.split(":", 1)
        else:
            user, password = auth, ""

        if ":" in host_port:
            host, port_str = host_port.split(":", 1)
            port = int(port_str)
        else:
            host, port = host_port, 5432

        # Remove any query parameters if present.
        if "?" in database:
            database = database.split("?", 1)[0]

        return {
            "user": user,
            "password": password,
            "host": host,
            "port": port,
            "database": database,
        }

    async def _create_tables(self) -> None:
        """
        Create necessary schema/tables if not present.
        """
        async with self.pool.acquire() as conn:
            # Ensure the schema exists.
            await conn.execute(f"CREATE SCHEMA IF NOT EXISTS {self.schema}")

            # Main jobs table.
            await conn.execute(
                f"""
                CREATE TABLE IF NOT EXISTS {self.schema}.jobs (
                    id TEXT PRIMARY KEY,
                    title TEXT,
                    url TEXT,
                    locations JSONB,
                    work_types JSONB,
                    salary JSONB,
                    gender TEXT,
                    tags JSONB,
                    item_index INTEGER,
                    job_post_categories JSONB,
                    company_fa_name TEXT,
                    province_match_city TEXT,
                    normalize_salary_min FLOAT,
                    normalize_salary_max FLOAT,
                    payment_method TEXT,
                    district TEXT,
                    company_title_fa TEXT,
                    job_board_id TEXT,
                    job_board_title_en TEXT,
                    activation_time TIMESTAMP,
                    company_id TEXT,
                    company_name_fa TEXT,
                    company_name_en TEXT,
                    company_about TEXT,
                    company_url TEXT,
                    location_ids TEXT,
                    tag_number TEXT,
                    raw_data JSONB,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    batch_id TEXT,
                    batch_date TIMESTAMP
                )
                """
            )

            # Temporary table for staging bulk upserts.
            await conn.execute(
                f"""
                CREATE TABLE IF NOT EXISTS {self.schema}.jobs_temp (
                    LIKE {self.schema}.jobs INCLUDING ALL
                )
                """
            )
            # Remove the primary key constraint from the staging table.
            await conn.execute(
                f"ALTER TABLE {self.schema}.jobs_temp DROP CONSTRAINT IF EXISTS jobs_temp_pkey"
            )

            # Table for tracking batches.
            await conn.execute(
                f"""
                CREATE TABLE IF NOT EXISTS {self.schema}.job_batches (
                    batch_id TEXT PRIMARY KEY,
                    batch_date TIMESTAMP,
                    job_count INTEGER,
                    source TEXT,
                    processing_time FLOAT,
                    status TEXT,
                    error_message TEXT,
                    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                    completed_at TIMESTAMP
                )
                """
            )

            # Table for recording overall scraper statistics.
            await conn.execute(
                f"""
                CREATE TABLE IF NOT EXISTS {self.schema}.scraper_stats (
                    id SERIAL PRIMARY KEY,
                    run_date TIMESTAMP,
                    total_jobs_scraped INTEGER,
                    new_jobs_found INTEGER,
                    pages_processed INTEGER,
                    processing_time FLOAT,
                    errors INTEGER,
                    status TEXT,
                    metadata JSONB
                )
                """
            )

            # Useful indexes.
            await conn.execute(
                f"CREATE INDEX IF NOT EXISTS idx_jobs_activation_time ON {self.schema}.jobs (activation_time)"
            )
            await conn.execute(
                f"CREATE INDEX IF NOT EXISTS idx_jobs_batch_id ON {self.schema}.jobs (batch_id)"
            )
            await conn.execute(
                f"CREATE INDEX IF NOT EXISTS idx_jobs_company_id ON {self.schema}.jobs (company_id) WHERE company_id IS NOT NULL"
            )

            # Trigger function to auto-update the 'updated_at' column.
            await conn.execute(
                f"""
                CREATE OR REPLACE FUNCTION {self.schema}.update_updated_at_column()
                RETURNS TRIGGER AS $$
                BEGIN
                    NEW.updated_at = NOW();
                    RETURN NEW;
                END;
                $$ LANGUAGE 'plpgsql';
                """
            )
            await conn.execute(
                f"""
                DROP TRIGGER IF EXISTS update_jobs_updated_at ON {self.schema}.jobs;
                CREATE TRIGGER update_jobs_updated_at
                BEFORE UPDATE ON {self.schema}.jobs
                FOR EACH ROW
                EXECUTE FUNCTION {self.schema}.update_updated_at_column();
                """
            )

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=1, min=4, max=10),
        retry=retry_if_exception_type((asyncpg.exceptions.ConnectionDoesNotExistError,
                                        asyncpg.exceptions.InterfaceError))
    )
    async def insert_jobs(self, jobs: List[Dict[str, Any]], batch_id: str) -> int:
        """
        Insert or update jobs in the database using a temporary table and UPSERT.
        Automatically retries on connection errors.

        Args:
            jobs (List[Dict[str, Any]]): The job records to insert.
            batch_id (str): UUID for this batch (for tracking).

        Returns:
            int: Number of jobs inserted or updated.
        """
        if not jobs:
            return 0
            
        # Ensure connection is valid before proceeding
        if not await self.ensure_connection():
            logger.error("Database connection is not available for job insertion")
            return 0

        try:
            start_time = time.time()
            batch_date = datetime.now()
            job_data = []

            # Create batch entry first
            await self._start_batch(batch_id, batch_date, len(jobs))

            # Transform jobs for DB insertion (type conversion, field extraction)
            for job in jobs:
                try:
                    db_job = self._transform_job_for_db(job, batch_id, batch_date)
                    job_data.append(db_job)
                except Exception as e:
                    logger.error(f"Error transforming job {job.get('id', 'unknown')}: {str(e)}")
                    continue

            # Use connection pool to get a DB connection
            async with self.pool.acquire() as conn:
                async with conn.transaction():
                    # 1. Truncate staging table
                    await conn.execute(f"TRUNCATE TABLE {self.schema}.jobs_temp")

                    # 2. Insert all jobs into the staging table in chunks
                    inserted = 0
                    for i in range(0, len(job_data), self.batch_size):
                        chunk = job_data[i:i + self.batch_size]
                        column_names = list(chunk[0].keys())
                        column_str = ", ".join(column_names)
                        placeholders = []
                        values = []

                        # Build the VALUES clause and parameter list
                        for record in chunk:
                            placeholder_row = []
                            for col in column_names:
                                values.append(record.get(col))
                                placeholder_row.append(f"${len(values)}")
                            placeholders.append(f"({', '.join(placeholder_row)})")

                        # Perform insertion
                        insert_query = f"""
                            INSERT INTO {self.schema}.jobs_temp ({column_str})
                            VALUES {', '.join(placeholders)}
                        """
                        await conn.execute(insert_query, *values)
                        inserted += len(chunk)

                    # 3. Use UPSERT/INSERT ON CONFLICT to merge data
                    # This handles both inserts and updates in one operation
                    result = await conn.execute(f"""
                        INSERT INTO {self.schema}.jobs (
                            id, title, url, locations, work_types, salary,
                            gender, tags, item_index, job_post_categories,
                            company_fa_name, province_match_city, normalize_salary_min,
                            normalize_salary_max, payment_method, district,
                            company_title_fa, job_board_id, job_board_title_en,
                            activation_time, company_id, company_name_fa,
                            company_name_en, company_about, company_url,
                            location_ids, tag_number, raw_data, batch_id, batch_date
                        )
                        SELECT 
                            id, title, url, locations, work_types, salary,
                            gender, tags, item_index, job_post_categories,
                            company_fa_name, province_match_city, normalize_salary_min,
                            normalize_salary_max, payment_method, district,
                            company_title_fa, job_board_id, job_board_title_en,
                            activation_time, company_id, company_name_fa,
                            company_name_en, company_about, company_url,
                            location_ids, tag_number, raw_data, batch_id, batch_date
                        FROM {self.schema}.jobs_temp
                        ON CONFLICT (id) DO UPDATE SET
                            title = EXCLUDED.title,
                            url = EXCLUDED.url,
                            locations = EXCLUDED.locations,
                            work_types = EXCLUDED.work_types,
                            salary = EXCLUDED.salary,
                            gender = EXCLUDED.gender,
                            tags = EXCLUDED.tags,
                            item_index = EXCLUDED.item_index,
                            job_post_categories = EXCLUDED.job_post_categories,
                            company_fa_name = EXCLUDED.company_fa_name,
                            province_match_city = EXCLUDED.province_match_city,
                            normalize_salary_min = EXCLUDED.normalize_salary_min,
                            normalize_salary_max = EXCLUDED.normalize_salary_max,
                            payment_method = EXCLUDED.payment_method,
                            district = EXCLUDED.district,
                            company_title_fa = EXCLUDED.company_title_fa,
                            job_board_id = EXCLUDED.job_board_id,
                            job_board_title_en = EXCLUDED.job_board_title_en,
                            activation_time = EXCLUDED.activation_time,
                            company_id = EXCLUDED.company_id,
                            company_name_fa = EXCLUDED.company_name_fa,
                            company_name_en = EXCLUDED.company_name_en,
                            company_about = EXCLUDED.company_about,
                            company_url = EXCLUDED.company_url,
                            location_ids = EXCLUDED.location_ids,
                            tag_number = EXCLUDED.tag_number,
                            raw_data = EXCLUDED.raw_data,
                            batch_id = EXCLUDED.batch_id,
                            batch_date = EXCLUDED.batch_date,
                            updated_at = NOW()
                    """)

            # Extract operation counts (format: "INSERT 0 42")
            processing_time = time.time() - start_time
            insert_count = inserted

            # Update metrics
            self.metrics["total_batches"] += 1
            self.metrics["total_jobs_inserted"] += insert_count
            avg_time = self.metrics["avg_insertion_time"]
            self.metrics["avg_insertion_time"] = (avg_time * (self.metrics["total_batches"] - 1) +
                                                processing_time) / self.metrics["total_batches"]

            # Record batch completion
            await self._complete_batch(batch_id, batch_date, insert_count, processing_time)

            logger.info(f"Upserted {insert_count} jobs in {processing_time:.2f}s")
            return insert_count

        except Exception as e:
            logger.error(f"Error in insert_jobs: {str(e)}")
            logger.error(traceback.format_exc())
            try:
                # Record batch failure but don't fail if this fails
                await self._fail_batch(batch_id, batch_date, str(e))
            except Exception:
                pass
            self.metrics["failed_operations"] += 1
            return 0

    def _transform_job_for_db(
        self,
        job: Dict[str, Any],
        batch_id: str,
        batch_date: datetime
    ) -> Dict[str, Any]:
        """
        Transform a raw job dictionary into a dictionary suitable for DB insertion.
        This function explicitly casts values for TEXT columns to strings and
        converts numeric fields appropriately.

        Args:
            job (Dict[str, Any]): The raw job data from the API.
            batch_id (str): The current batch identifier.
            batch_date (datetime): Timestamp for the batch.

        Returns:
            Dict[str, Any]: Transformed job data with proper types.
        """
        # Convert activation time string to datetime object.
        activation_time = None
        if "activationTime" in job and isinstance(job["activationTime"], dict):
            date_str = job["activationTime"].get("date")
            if date_str:
                for fmt in ["%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M"]:
                    try:
                        activation_time = datetime.strptime(date_str, fmt)
                        break
                    except ValueError:
                        continue

        # Build a string for location IDs (e.g., "001,002").
        location_ids = []
        locs = job.get("locations", [])
        if isinstance(locs, list):
            for loc in locs:
                if isinstance(loc, dict):
                    province_obj = loc.get("province")
                    city_obj = loc.get("city")
                    if province_obj and "id" in province_obj:
                        location_ids.append(province_obj["id"])
                    if city_obj and "id" in city_obj:
                        location_ids.append(city_obj["id"])
        location_ids_str = ",".join(f"{lid_:03d}" for lid_ in location_ids) if location_ids else ""

        # Return the transformed job record.
        # Note: For columns defined as TEXT in the schema, we convert the value to a string.
        return {
            "id": str(job.get("id")) if job.get("id") is not None else None,
            "title": str(job.get("title")) if job.get("title") is not None else None,
            "url": str(job.get("url")) if job.get("url") is not None else None,
            "locations": self._safe_json_dumps(job.get("locations", [])),
            "work_types": self._safe_json_dumps(job.get("workTypes", [])),
            "salary": self._safe_json_dumps(job.get("salary", "")),
            "gender": str(job.get("gender")) if job.get("gender") is not None else None,
            "tags": self._safe_json_dumps(job.get("tags", [])),
            "item_index": job.get("itemIndex"),
            "job_post_categories": self._safe_json_dumps(job.get("jobPostCategories", [])),
            "company_fa_name": str(job.get("companyFaName")) if job.get("companyFaName") is not None else None,
            "province_match_city": str(job.get("provinceMatchCity")) if job.get("provinceMatchCity") is not None else None,
            "normalize_salary_min": float(job.get("normalizeSalaryMin")) if job.get("normalizeSalaryMin") is not None else None,
            "normalize_salary_max": float(job.get("normalizeSalaryMax")) if job.get("normalizeSalaryMax") is not None else None,
            "payment_method": str(job.get("paymentMethod")) if job.get("paymentMethod") is not None else None,
            "district": str(job.get("district")) if job.get("district") is not None else None,
            "company_title_fa": str(job.get("companyTitleFa")) if job.get("companyTitleFa") is not None else None,
            "job_board_id": str(job.get("jobBoardId")) if job.get("jobBoardId") is not None else None,
            "job_board_title_en": str(job.get("jobBoardTitleEn")) if job.get("jobBoardTitleEn") is not None else None,
            "activation_time": activation_time,
            "company_id": str(job.get("companyDetailsSummary", {}).get("id")) if job.get("companyDetailsSummary", {}).get("id") is not None else None,
            "company_name_fa": str(job.get("companyDetailsSummary", {}).get("name", {}).get("titleFa")) if job.get("companyDetailsSummary", {}).get("name", {}).get("titleFa") is not None else None,
            "company_name_en": str(job.get("companyDetailsSummary", {}).get("name", {}).get("titleEn")) if job.get("companyDetailsSummary", {}).get("name", {}).get("titleEn") is not None else None,
            "company_about": str(job.get("companyDetailsSummary", {}).get("about", {}).get("titleFa")) if job.get("companyDetailsSummary", {}).get("about", {}).get("titleFa") is not None else None,
            "company_url": str(job.get("companyDetailsSummary", {}).get("url")) if job.get("companyDetailsSummary", {}).get("url") is not None else None,
            "location_ids": location_ids_str,
            "tag_number": self._extract_tag_number(job),
            "raw_data": self._safe_json_dumps(job),
            "batch_id": str(batch_id),
            "batch_date": batch_date,
        }

    def _extract_tag_number(self, job: Dict[str, Any]) -> str:
        """
        Convert textual tags to numeric codes. Returns a comma-separated
        string of codes based on a predefined mapping.

        Args:
            job (Dict[str, Any]): A job record.

        Returns:
            str: Comma-separated numeric codes, or "0" if no tags.
        """
        tag_map = {
            "پاره وقت": 1,
            "بدون نیاز به سابقه": 2,
            "پروژه ای": 3,
            "کارآموزی": 4,
        }
        tags_list = job.get("tags", [])
        if not isinstance(tags_list, list):
            return "0"

        numeric_tags = [tag_map.get(t, 0) for t in tags_list]
        unique_sorted_codes = sorted(set(numeric_tags))
        if unique_sorted_codes:
            return ",".join(str(x) for x in unique_sorted_codes)
        return "0"

    def _safe_json_dumps(self, obj: Any) -> str:
        """
        Safely serialize an object to JSON. If serialization fails,
        return an appropriate fallback.

        Args:
            obj (Any): The object to serialize.

        Returns:
            str: JSON string or a fallback string.
        """
        try:
            # Handle common cases that might cause JSON serialization issues
            if isinstance(obj, str):
                # If it's already a string, just return a JSON string representation
                return json.dumps(obj, ensure_ascii=False)
            elif obj is None:
                # Explicitly handle None
                return 'null'
            else:
                # Normal JSON serialization for other types
                return json.dumps(obj, ensure_ascii=False)
        except (TypeError, ValueError, OverflowError) as e:
            logger.warning(f"Error serializing to JSON: {str(e)}")
            if isinstance(obj, dict):
                return "{}"
            elif isinstance(obj, list):
                return "[]"
            elif isinstance(obj, str):
                # For strings that failed to serialize (rare, but possible with invalid UTF-8)
                # Create safe simple string
                try:
                    return json.dumps(obj.encode('utf-8', errors='replace').decode('utf-8'), ensure_ascii=False)
                except:
                    return '""'
            else:
                return '""'

    async def _start_batch(self, batch_id: str, batch_date: datetime, job_count: int) -> None:
        """
        Record the start of a batch by inserting a record into the job_batches table.

        Args:
            batch_id (str): Unique batch identifier.
            batch_date (datetime): Timestamp when the batch started.
            job_count (int): Number of jobs in the batch.
        """
        try:
            async with self.pool.acquire() as conn:
                await conn.execute(
                    f"""
                    INSERT INTO {self.schema}.job_batches
                    (batch_id, batch_date, job_count, source, processing_time, status, created_at)
                    VALUES ($1, $2, $3, $4, $5, $6, $7)
                    ON CONFLICT (batch_id)
                    DO UPDATE
                      SET job_count = $3,
                          status = $6,
                          created_at = $7
                    """,
                    batch_id,
                    batch_date,
                    job_count,
                    "api_scraper",
                    0.0,
                    "processing",
                    datetime.now(),
                )
        except Exception as e:
            logger.error(f"Failed to record batch start for {batch_id}: {str(e)}")

    async def _complete_batch(
        self,
        batch_id: str,
        batch_date: datetime,
        job_count: int,
        processing_time: float
    ) -> None:
        """
        Mark a batch as complete by updating the job_batches table.

        Args:
            batch_id (str): Batch identifier.
            batch_date (datetime): Original batch timestamp.
            job_count (int): Number of jobs processed.
            processing_time (float): Total processing time in seconds.
        """
        try:
            async with self.pool.acquire() as conn:
                await conn.execute(
                    f"""
                    INSERT INTO {self.schema}.job_batches
                    (batch_id, batch_date, job_count, source, processing_time, status, completed_at)
                    VALUES ($1, $2, $3, $4, $5, $6, $7)
                    ON CONFLICT (batch_id)
                    DO UPDATE
                      SET job_count = $3,
                          processing_time = $5,
                          status = $6,
                          completed_at = $7
                    """,
                    batch_id,
                    batch_date,
                    job_count,
                    "api_scraper",
                    processing_time,
                    "completed",
                    datetime.now(),
                )
        except Exception as e:
            logger.error(f"Failed to record batch completion for {batch_id}: {str(e)}")

    async def _fail_batch(
        self,
        batch_id: str,
        batch_date: datetime,
        error_message: str
    ) -> None:
        """
        Mark a batch as failed in the job_batches table, storing the error message.

        Args:
            batch_id (str): Batch identifier.
            batch_date (datetime): Batch start timestamp.
            error_message (str): Error details.
        """
        try:
            async with self.pool.acquire() as conn:
                await conn.execute(
                    f"""
                    INSERT INTO {self.schema}.job_batches
                    (batch_id, batch_date, source, status, error_message, completed_at)
                    VALUES ($1, $2, $3, $4, $5, $6)
                    ON CONFLICT (batch_id)
                    DO UPDATE
                      SET status = $4,
                          error_message = $5,
                          completed_at = $6
                    """,
                    batch_id,
                    batch_date,
                    "api_scraper",
                    "failed",
                    error_message,
                    datetime.now(),
                )
        except Exception as e:
            logger.error(f"Failed to record batch failure for {batch_id}: {str(e)}")

    async def get_job_count(self) -> int:
        """
        Retrieve the total number of job records in the jobs table.

        Returns:
            int: Count of jobs.
        """
        if not self.pool:
            return 0
        try:
            async with self.pool.acquire() as conn:
                return await conn.fetchval(f"SELECT COUNT(*) FROM {self.schema}.jobs")
        except Exception as e:
            logger.error(f"Error getting job count: {str(e)}")
            return 0

    async def record_scraper_stats(self, stats: Dict[str, Any]) -> bool:
        """
        Insert a record of scraper run statistics into the scraper_stats table.

        Args:
            stats (Dict[str, Any]): Dictionary containing run statistics.

        Returns:
            bool: True if recording succeeded, else False.
        """
        if not self.pool:
            return False
        try:
            async with self.pool.acquire() as conn:
                await conn.execute(
                    f"""
                    INSERT INTO {self.schema}.scraper_stats
                    (run_date, total_jobs_scraped, new_jobs_found, pages_processed,
                     processing_time, errors, status, metadata)
                    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                    """,
                    datetime.now(),
                    stats.get("total_jobs_scraped", 0),
                    stats.get("new_jobs_found", 0),
                    stats.get("pages_processed", 0),
                    stats.get("processing_time", 0.0),
                    stats.get("errors", 0),
                    stats.get("status", "completed"),
                    json.dumps(stats.get("metadata", {})),
                )
            return True
        except Exception as e:
            logger.error(f"Error recording scraper stats: {str(e)}")
            return False

    async def close(self) -> None:
        """
        Cleanly close the asyncpg pool and dispose of the SQLAlchemy engine.
        """
        if self.pool:
            await self.pool.close()
        if self.engine:
            self.engine.dispose()
        logger.info("Database connections closed")
