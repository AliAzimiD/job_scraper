"""
Script to update the database manager to work with the new schema.
This script provides new versions of the database manager methods.
"""

import logging
import asyncio
import json
from typing import Dict, List, Any, Optional, Union
from datetime import datetime

# This is a standalone script that will need to be integrated into db_manager.py

class DatabaseManagerUpdated:
    """
    Updated methods for DatabaseManager with normalized schema support.
    """

    async def _create_tables_updated(self) -> None:
        """
        Create necessary schema/tables if not present, updated for the new schema.
        This includes creating normalized tables and links to migration scripts.
        """
        async with self.pool.acquire() as conn:
            # Check if our schema version table exists
            schema_version_exists = await conn.fetchval(
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
                await conn.execute(
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
                await conn.execute(
                    f"""
                    INSERT INTO {self.schema}.schema_version (version, description)
                    VALUES (1, 'Initial schema creation')
                    """
                )
            
            # Get current schema version
            current_version = await conn.fetchval(
                f"SELECT MAX(version) FROM {self.schema}.schema_version"
            )
            
            # If schema needs to be upgraded to version 2
            if current_version < 2:
                logger.info("Upgrading database schema to version 2...")
                
                # Run our migration scripts
                migration_files = [
                    "/root/karchi/job_scraper/migrations/01_create_normalized_schema.sql",
                    "/root/karchi/job_scraper/migrations/02_migrate_data.sql",
                    "/root/karchi/job_scraper/migrations/03_create_materialized_views.sql",
                    "/root/karchi/job_scraper/migrations/04_setup_partitioning.sql",
                    "/root/karchi/job_scraper/migrations/05_modify_database_access.sql"
                ]
                
                for migration_file in migration_files:
                    try:
                        with open(migration_file, 'r', encoding='utf-8') as f:
                            migration_sql = f.read()
                            await conn.execute(migration_sql)
                            logger.info(f"Applied migration: {migration_file}")
                    except Exception as e:
                        logger.error(f"Error applying migration {migration_file}: {str(e)}")
                        raise
                
                # Update schema version
                await conn.execute(
                    f"""
                    INSERT INTO {self.schema}.schema_version (version, description)
                    VALUES (2, 'Normalized schema with tags, categories, and companies')
                    """
                )
                
                logger.info("Database schema upgraded to version 2 successfully")
            else:
                logger.info(f"Current database schema version: {current_version}")

    async def insert_jobs_normalized(self, jobs: List[Dict[str, Any]], batch_id: str) -> int:
        """
        Insert jobs using the new normalized schema and functions.
        
        Args:
            jobs: List of job dictionaries
            batch_id: Unique ID for this batch
            
        Returns:
            int: Number of jobs successfully processed
        """
        if not jobs:
            return 0
            
        batch_date = datetime.now()
        job_count = len(jobs)
        
        try:
            # Start transaction to track the batch
            await self._start_batch(batch_id, batch_date, job_count)
            
            # Track metrics
            start_time = time.time()
            processed_count = 0
            
            # Process jobs in smaller chunks
            chunk_size = min(self.batch_size, 100)  # Use smaller chunks for complex operations
            
            for i in range(0, len(jobs), chunk_size):
                chunk = jobs[i:i+chunk_size]
                
                async with self.pool.acquire() as conn:
                    # Process each job through our insert_job DB function
                    for job in chunk:
                        try:
                            db_job = self._transform_job_for_db(job, batch_id, batch_date)
                            
                            # Call the DB function that handles normalized inserts
                            await conn.fetchval(
                                f"""
                                SELECT insert_job(
                                    $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
                                    $11, $12, $13, $14, $15, $16, $17, $18, $19, $20,
                                    $21, $22, $23, $24, $25, $26, $27, $28, $29, $30
                                )
                                """,
                                db_job.get("id"),
                                db_job.get("title"),
                                db_job.get("url"),
                                db_job.get("locations"),
                                db_job.get("work_types"),
                                db_job.get("salary"),
                                db_job.get("gender"),
                                db_job.get("tags"),
                                db_job.get("item_index"),
                                db_job.get("job_post_categories"),
                                db_job.get("company_fa_name"),
                                db_job.get("province_match_city"),
                                db_job.get("normalize_salary_min"),
                                db_job.get("normalize_salary_max"),
                                db_job.get("payment_method"),
                                db_job.get("district"),
                                db_job.get("company_title_fa"),
                                db_job.get("job_board_id"),
                                db_job.get("job_board_title_en"),
                                db_job.get("activation_time"),
                                db_job.get("company_id"),
                                db_job.get("company_name_fa"),
                                db_job.get("company_name_en"),
                                db_job.get("company_about"),
                                db_job.get("company_url"),
                                db_job.get("location_ids"),
                                db_job.get("tag_number"),
                                db_job.get("raw_data"),
                                db_job.get("batch_id"),
                                db_job.get("batch_date")
                            )
                            processed_count += 1
                        except Exception as e:
                            logger.error(f"Error inserting job {job.get('id')}: {str(e)}")
                            self.metrics["failed_operations"] += 1
            
            # Update batch status
            processing_time = time.time() - start_time
            await self._complete_batch(batch_id, batch_date, processed_count, processing_time)
            
            # Update metrics
            self.metrics["total_jobs_inserted"] += processed_count
            self.metrics["total_batches"] += 1
            self.metrics["avg_insertion_time"] = (
                (self.metrics["avg_insertion_time"] * (self.metrics["total_batches"] - 1) + processing_time)
                / self.metrics["total_batches"]
            )
            
            logger.info(
                f"Successfully processed {processed_count}/{job_count} jobs "
                f"in {processing_time:.2f}s"
            )
            
            return processed_count
            
        except Exception as e:
            logger.error(f"Error in batch job insertion: {str(e)}")
            await self._fail_batch(batch_id, batch_date, str(e))
            self.metrics["failed_operations"] += 1
            return 0

    async def _complete_batch_normalized(
        self,
        batch_id: str,
        batch_date: datetime,
        job_count: int,
        processing_time: float
    ) -> None:
        """
        Mark a batch as completed using the new job_batches_new table.
        
        Args:
            batch_id: The ID of the batch
            batch_date: The date of the batch
            job_count: Number of jobs in the batch
            processing_time: Time taken to process the batch
        """
        try:
            async with self.pool.acquire() as conn:
                # Use the update_job_batch function
                await conn.fetchval(
                    """
                    SELECT update_job_batch($1, $2, $3, $4, $5, $6)
                    """,
                    batch_id,
                    "job_scraper",  # scraper_name
                    batch_date,
                    "completed",  # status
                    job_count,
                    None  # error_message
                )
                
                # Refresh materialized views after batch completion
                await conn.execute("SELECT refresh_materialized_views()")
                
                logger.info(f"Batch {batch_id} completed with {job_count} jobs")
        except Exception as e:
            logger.error(f"Error marking batch {batch_id} as completed: {str(e)}")

    async def _fail_batch_normalized(
        self,
        batch_id: str,
        batch_date: datetime,
        error_message: str
    ) -> None:
        """
        Mark a batch as failed using the new job_batches_new table.
        
        Args:
            batch_id: The ID of the batch
            batch_date: The date of the batch
            error_message: Error details
        """
        try:
            async with self.pool.acquire() as conn:
                # Use the update_job_batch function
                await conn.fetchval(
                    """
                    SELECT update_job_batch($1, $2, $3, $4, $5, $6)
                    """,
                    batch_id,
                    "job_scraper",  # scraper_name
                    batch_date,
                    "failed",  # status
                    0,  # job_count
                    error_message
                )
                
                logger.warning(f"Batch {batch_id} failed: {error_message}")
        except Exception as e:
            logger.error(f"Error marking batch {batch_id} as failed: {str(e)}")

    async def get_job_count_normalized(self) -> int:
        """
        Get the total count of jobs using the partitioned table.
        
        Returns:
            int: Total job count
        """
        try:
            async with self.pool.acquire() as conn:
                return await conn.fetchval("SELECT COUNT(*) FROM jobs_partitioned")
        except Exception as e:
            logger.error(f"Error getting job count: {str(e)}")
            return 0

# Implementation note: To integrate these methods, you would:
# 1. Add these methods to the DatabaseManager class
# 2. Update _create_tables() to call _create_tables_updated()
# 3. Replace insert_jobs() with insert_jobs_normalized()
# 4. Replace _complete_batch() with _complete_batch_normalized()
# 5. Replace _fail_batch() with _fail_batch_normalized()
# 6. Replace get_job_count() with get_job_count_normalized() 