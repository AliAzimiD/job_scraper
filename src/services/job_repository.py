from typing import Dict, Any, List, Optional, Tuple, Union
from datetime import datetime
import json

from ..models.job import Job
from .db_service import get_db_service, DatabaseService
from ..log_setup import get_logger

# Get logger
logger = get_logger("job_repository")

class JobRepository:
    """
    Repository for job data operations.
    Handles CRUD operations and specialized queries for job data.
    """
    
    def __init__(self, db_service: Optional[DatabaseService] = None):
        """
        Initialize the job repository.
        
        Args:
            db_service: Database service to use
        """
        self.db = db_service or get_db_service()
    
    def get_job_count(self) -> int:
        """
        Get the total number of jobs in the database.
        
        Returns:
            Total job count
        """
        try:
            query = f"SELECT COUNT(*) FROM {self.db.schema}.jobs"
            result = self.db.execute_query(query, fetch_one=True)
            return result[0] if result else 0
        except Exception as e:
            logger.error(f"Error getting job count: {e}")
            return 0
    
    def get_job_by_id(self, job_id: str) -> Optional[Job]:
        """
        Get a job by its ID.
        
        Args:
            job_id: Job ID to find
            
        Returns:
            Job object if found, None otherwise
        """
        try:
            query = f"SELECT * FROM {self.db.schema}.jobs WHERE id = %s"
            result = self.db.execute_query(query, (job_id,), fetch_one=True, dict_cursor=True)
            
            if not result:
                return None
                
            # Convert row dict to Job object
            return Job(**result)
        except Exception as e:
            logger.error(f"Error getting job by ID {job_id}: {e}")
            return None
    
    def get_recent_jobs(self, limit: int = 10) -> List[Job]:
        """
        Get the most recent jobs.
        
        Args:
            limit: Maximum number of jobs to return
            
        Returns:
            List of recent Job objects
        """
        try:
            query = f"""
                SELECT id, title, company_name_en, company_name_fa, activation_time, url
                FROM {self.db.schema}.jobs
                ORDER BY activation_time DESC
                LIMIT %s
            """
            rows = self.db.execute_query(query, (limit,), fetch=True, dict_cursor=True)
            
            return [Job(**row) for row in rows] if rows else []
        except Exception as e:
            logger.error(f"Error getting recent jobs: {e}")
            return []
    
    def get_filtered_jobs(
        self, 
        filters: Dict[str, Any],
        limit: int = 100,
        offset: int = 0
    ) -> List[Job]:
        """
        Get jobs with filtering options.
        
        Args:
            filters: Dictionary of filter criteria
            limit: Maximum number of jobs to return
            offset: Number of jobs to skip
            
        Returns:
            List of filtered Job objects
        """
        where_clauses = []
        params = []
        
        # Apply filters
        if filters.get('date_from'):
            where_clauses.append("activation_time >= %s")
            params.append(filters['date_from'])
            
        if filters.get('date_to'):
            where_clauses.append("activation_time <= %s")
            params.append(filters['date_to'])
            
        if filters.get('keywords'):
            where_clauses.append("title ILIKE %s")
            params.append(f"%{filters['keywords']}%")
            
        if filters.get('company'):
            where_clauses.append("company_name_en ILIKE %s")
            params.append(f"%{filters['company']}%")
            
        if filters.get('remote') and filters['remote'] is True:
            where_clauses.append("tag_remote = 1")
            
        if filters.get('no_experience') and filters['no_experience'] is True:
            where_clauses.append("tag_no_experience = 1")
            
        if filters.get('category'):
            where_clauses.append("category ILIKE %s")
            params.append(f"%{filters['category']}%")
            
        # Build query
        where_clause = " AND ".join(where_clauses) if where_clauses else "TRUE"
        
        query = f"""
            SELECT id, title, company_name_en, company_name_fa, activation_time, 
                   url, salary, locations, primary_city, category, 
                   tag_remote, tag_no_experience, tag_part_time, tag_internship
            FROM {self.db.schema}.jobs
            WHERE {where_clause}
            ORDER BY activation_time DESC
            LIMIT %s OFFSET %s
        """
        
        # Add limit and offset to params
        params.append(limit)
        params.append(offset)
        
        try:
            rows = self.db.execute_query(query, tuple(params), fetch=True, dict_cursor=True)
            return [Job(**row) for row in rows] if rows else []
        except Exception as e:
            logger.error(f"Error getting filtered jobs: {e}")
            return []
    
    def upsert_job(self, job: Job) -> bool:
        """
        Insert or update a job in the database.
        
        Args:
            job: Job object to insert or update
            
        Returns:
            True if successful, False otherwise
        """
        try:
            # Prepare locations and raw_data for JSON serialization
            locations_json = None
            if job.locations:
                if isinstance(job.locations, str):
                    locations_json = job.locations
                else:
                    locations_json = json.dumps(job.locations, ensure_ascii=False)
            
            raw_data_json = None
            if job.raw_data:
                if isinstance(job.raw_data, str):
                    raw_data_json = job.raw_data
                else:
                    raw_data_json = json.dumps(job.raw_data, ensure_ascii=False)
            
            # Build the query
            query = f"""
                INSERT INTO {self.db.schema}.jobs 
                (id, title, company_name_en, company_name_fa, activation_time, 
                 locations, salary, url, raw_data)
                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                ON CONFLICT (id) DO UPDATE SET 
                title = EXCLUDED.title,
                company_name_en = EXCLUDED.company_name_en,
                company_name_fa = EXCLUDED.company_name_fa,
                activation_time = EXCLUDED.activation_time,
                locations = EXCLUDED.locations,
                salary = EXCLUDED.salary,
                url = EXCLUDED.url,
                raw_data = EXCLUDED.raw_data,
                updated_at = CURRENT_TIMESTAMP
                RETURNING (xmax = 0) AS inserted
            """
            
            # Execute the query
            result = self.db.execute_query(
                query,
                (
                    job.id,
                    job.title,
                    job.company_name_en,
                    job.company_name_fa,
                    job.activation_time,
                    locations_json,
                    job.salary,
                    job.url,
                    raw_data_json
                ),
                fetch_one=True
            )
            
            # Log result
            if result and result[0]:
                logger.info(f"Inserted new job: {job.id}")
            else:
                logger.info(f"Updated existing job: {job.id}")
            
            return True
        except Exception as e:
            logger.error(f"Error upserting job {job.id}: {e}")
            return False
    
    def bulk_upsert_jobs(self, jobs: List[Job]) -> Tuple[int, int]:
        """
        Insert or update multiple jobs efficiently.
        
        Args:
            jobs: List of Job objects to insert or update
            
        Returns:
            Tuple of (inserted_count, updated_count)
        """
        if not jobs:
            return (0, 0)
            
        inserted_count = 0
        updated_count = 0
        
        try:
            with self.db.get_connection() as conn:
                with conn.cursor() as cursor:
                    for job in jobs:
                        try:
                            # Prepare JSON data
                            locations_json = None
                            if job.locations:
                                locations_json = json.dumps(job.locations, ensure_ascii=False) \
                                    if not isinstance(job.locations, str) else job.locations
                            
                            raw_data_json = None
                            if job.raw_data:
                                raw_data_json = json.dumps(job.raw_data, ensure_ascii=False) \
                                    if not isinstance(job.raw_data, str) else job.raw_data
                            
                            # Execute upsert
                            cursor.execute(
                                f"""
                                INSERT INTO {self.db.schema}.jobs 
                                (id, title, company_name_en, company_name_fa, activation_time, 
                                locations, salary, url, raw_data)
                                VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s)
                                ON CONFLICT (id) DO UPDATE SET 
                                title = EXCLUDED.title,
                                company_name_en = EXCLUDED.company_name_en,
                                company_name_fa = EXCLUDED.company_name_fa,
                                activation_time = EXCLUDED.activation_time,
                                locations = EXCLUDED.locations,
                                salary = EXCLUDED.salary,
                                url = EXCLUDED.url,
                                raw_data = EXCLUDED.raw_data,
                                updated_at = CURRENT_TIMESTAMP
                                RETURNING (xmax = 0) AS inserted
                                """,
                                (
                                    job.id,
                                    job.title,
                                    job.company_name_en,
                                    job.company_name_fa,
                                    job.activation_time,
                                    locations_json,
                                    job.salary,
                                    job.url,
                                    raw_data_json
                                )
                            )
                            
                            # Check if inserted or updated
                            result = cursor.fetchone()
                            if result and result[0]:  # True if inserted, False if updated
                                inserted_count += 1
                            else:
                                updated_count += 1
                                
                        except Exception as e:
                            logger.error(f"Error processing job {job.id}: {e}")
                            conn.rollback()
                            continue
                    
                    # Commit transaction
                    conn.commit()
                    
            return (inserted_count, updated_count)
        except Exception as e:
            logger.error(f"Error in bulk upsert: {e}")
            return (inserted_count, updated_count)
    
    def delete_job(self, job_id: str) -> bool:
        """
        Delete a job from the database.
        
        Args:
            job_id: ID of the job to delete
            
        Returns:
            True if successful, False otherwise
        """
        try:
            query = f"DELETE FROM {self.db.schema}.jobs WHERE id = %s"
            self.db.execute_query(query, (job_id,))
            return True
        except Exception as e:
            logger.error(f"Error deleting job {job_id}: {e}")
            return False
    
    def get_job_statistics(self) -> Dict[str, Any]:
        """
        Get statistics about jobs in the database.
        
        Returns:
            Dictionary of job statistics
        """
        stats = {
            "total": 0,
            "by_date": {},
            "by_company": {},
            "by_job_board": {},
            "by_location": {},
            "by_category": {}
        }
        
        try:
            # Get total job count
            stats["total"] = self.get_job_count()
            
            # Get jobs by date (last 30 days)
            query = f"""
                SELECT 
                    DATE(activation_time) as date,
                    COUNT(*) as count
                FROM {self.db.schema}.jobs
                WHERE activation_time >= CURRENT_DATE - INTERVAL '30 days'
                GROUP BY DATE(activation_time)
                ORDER BY date DESC
            """
            rows = self.db.execute_query(query, fetch=True)
            for row in rows:
                date_str = row[0].isoformat()
                stats["by_date"][date_str] = row[1]
            
            # Get jobs by company
            query = f"""
                SELECT 
                    company_name_en,
                    COUNT(*) as count
                FROM {self.db.schema}.jobs
                WHERE company_name_en IS NOT NULL AND company_name_en != ''
                GROUP BY company_name_en
                ORDER BY count DESC
                LIMIT 10
            """
            rows = self.db.execute_query(query, fetch=True)
            for row in rows:
                stats["by_company"][row[0]] = row[1]
            
            # Try to get statistics from the derived columns
            try:
                # Get jobs by job board
                query = f"""
                    SELECT 
                        jobBoard_titleEn as job_board,
                        COUNT(*) as count
                    FROM {self.db.schema}.jobs
                    WHERE jobBoard_titleEn IS NOT NULL AND jobBoard_titleEn != ''
                    GROUP BY jobBoard_titleEn
                    ORDER BY count DESC
                    LIMIT 10
                """
                rows = self.db.execute_query(query, fetch=True)
                for row in rows:
                    stats["by_job_board"][row[0]] = row[1]
                
                # Get jobs by location
                query = f"""
                    SELECT 
                        primary_city as location,
                        COUNT(*) as count
                    FROM {self.db.schema}.jobs
                    WHERE primary_city IS NOT NULL AND primary_city != ''
                    GROUP BY primary_city
                    ORDER BY count DESC
                    LIMIT 10
                """
                rows = self.db.execute_query(query, fetch=True)
                for row in rows:
                    stats["by_location"][row[0]] = row[1]
                
                # Get jobs by category
                query = f"""
                    SELECT 
                        category,
                        COUNT(*) as count
                    FROM {self.db.schema}.jobs
                    WHERE category IS NOT NULL AND category != ''
                    GROUP BY category
                    ORDER BY count DESC
                    LIMIT 10
                """
                rows = self.db.execute_query(query, fetch=True)
                for row in rows:
                    stats["by_category"][row[0]] = row[1]
            except Exception as e:
                # Derived columns might not exist, just log the error
                logger.warning(f"Error getting derived column stats: {e}")
                
            return stats
        except Exception as e:
            logger.error(f"Error getting job statistics: {e}")
            return stats 