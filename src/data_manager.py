"""
Data Manager Module: Handles exporting and importing job data from different sources.
Provides backup and restore capabilities for job data.
"""

import asyncio
from datetime import datetime as dt
import json
import os
import shutil
import tempfile
import time
import traceback
import zipfile
from pathlib import Path
from typing import Dict, List, Optional, Union, Any, Tuple, BinaryIO

import aiofiles
import aiohttp
import asyncpg
import boto3
import pandas as pd
from botocore.exceptions import ClientError

from .db_manager import DatabaseManager
from .log_setup import get_logger

logger = get_logger("DataManager")


class DataManager:
    """
    Manages data export, import, and backup operations for job data.
    Supports multiple formats (JSON, CSV, Parquet) and storage backends.
    """

    def __init__(
        self,
        db_manager: Optional[DatabaseManager] = None,
        data_dir: str = "job_data",
        backup_dir: str = "backups",
    ) -> None:
        """
        Initialize the DataManager.

        Args:
            db_manager: DatabaseManager instance for DB operations
            data_dir: Base directory for job data
            backup_dir: Directory for storing backups
        """
        self.db_manager = db_manager
        self.data_dir = Path(data_dir)
        self.backup_dir = Path(backup_dir)
        self.data_dir.mkdir(exist_ok=True, parents=True)
        self.backup_dir.mkdir(exist_ok=True, parents=True)
        
        # Initialize metrics tracking
        self.metrics = {
            "exports": 0,
            "imports": 0, 
            "backups": 0,
            "restores": 0,
            "last_export": None,
            "last_import": None,
            "last_backup": None,
            "last_restore": None,
        }

    async def export_data(
        self, 
        format_type: str = "json", 
        output_file: Optional[str] = None,
        filters: Optional[Dict[str, Any]] = None,
        limit: int = 0,
        compress: bool = True
    ) -> str:
        """
        Export job data to a file.

        Args:
            format_type: Export format (json, csv, parquet)
            output_file: Output file path (defaults to auto-generated)
            filters: Optional filters to apply to the data
            limit: Maximum number of records (0 for all)
            compress: Whether to compress the output

        Returns:
            Path to the exported file
        """
        if not output_file:
            timestamp = dt.now().strftime("%Y%m%d_%H%M%S")
            output_file = f"job_export_{timestamp}.{format_type}"
            if compress:
                output_file += ".zip"
        
        output_path = self.data_dir / "exports" / output_file
        output_path.parent.mkdir(exist_ok=True, parents=True)
        
        # If no DB connection, try to load from local files
        if not self.db_manager or not self.db_manager.is_connected:
            logger.info("No DB connection, exporting from local files")
            jobs = await self._load_from_files()
        else:
            # Export from database
            logger.info(f"Exporting data from database in {format_type} format")
            jobs = await self._export_from_db(filters, limit)
        
        if not jobs:
            logger.warning("No data to export")
            return ""
        
        # Process the data based on format type
        temp_file = None
        try:
            if format_type == "json":
                temp_file = await self._export_json(jobs, compress)
            elif format_type == "csv":
                temp_file = await self._export_csv(jobs, compress)
            elif format_type == "parquet":
                temp_file = await self._export_parquet(jobs, compress)
            else:
                raise ValueError(f"Unsupported export format: {format_type}")
            
            # Move temp file to final destination
            if temp_file:
                if os.path.exists(output_path):
                    os.remove(output_path)
                shutil.move(temp_file, output_path)
                
            self.metrics["exports"] += 1
            self.metrics["last_export"] = dt.now().isoformat()
            
            logger.info(f"Data exported to {output_path} ({len(jobs)} records)")
            return str(output_path)
        
        except Exception as e:
            logger.error(f"Error exporting data: {str(e)}")
            logger.error(traceback.format_exc())
            if temp_file and os.path.exists(temp_file):
                os.remove(temp_file)
            raise
    
    async def import_data(
        self,
        file_path: str,
        format_type: Optional[str] = None,
        update_existing: bool = True,
        batch_size: int = 1000,
    ) -> Dict[str, Any]:
        """
        Import job data from a file.

        Args:
            file_path: Path to the import file
            format_type: File format (inferred from extension if None)
            update_existing: Whether to update existing records
            batch_size: Size of batches for DB operations

        Returns:
            Dictionary with import statistics
        """
        file_path = Path(file_path)
        if not file_path.exists():
            raise FileNotFoundError(f"Import file not found: {file_path}")
        
        # Auto-detect format from file extension if not specified
        if not format_type:
            if file_path.suffix == ".json" or file_path.suffix == ".zip" and file_path.stem.endswith(".json"):
                format_type = "json"
            elif file_path.suffix == ".csv" or file_path.suffix == ".zip" and file_path.stem.endswith(".csv"):
                format_type = "csv"
            elif file_path.suffix == ".parquet" or file_path.suffix == ".zip" and file_path.stem.endswith(".parquet"):
                format_type = "parquet"
            else:
                raise ValueError(f"Could not determine format type from file: {file_path}")
        
        # Handle compressed files
        is_compressed = file_path.suffix == ".zip"
        
        # Process the data based on format type
        jobs = []
        try:
            if format_type == "json":
                jobs = await self._import_json(file_path, is_compressed)
            elif format_type == "csv":
                jobs = await self._import_csv(file_path, is_compressed)
            elif format_type == "parquet":
                jobs = await self._import_parquet(file_path, is_compressed)
            else:
                raise ValueError(f"Unsupported import format: {format_type}")
            
            if not jobs:
                logger.warning("No data to import")
                return {"imported": 0, "status": "empty"}
            
            # Validate and normalize the imported data
            logger.info(f"Validating {len(jobs)} imported records")
            validated_jobs = self._validate_imported_jobs(jobs)
            
            # Store the data
            stats = await self._store_imported_data(validated_jobs, update_existing, batch_size)
            
            self.metrics["imports"] += 1
            self.metrics["last_import"] = dt.now().isoformat()
            
            logger.info(f"Data import completed: {stats}")
            return stats
        
        except Exception as e:
            logger.error(f"Error importing data: {str(e)}")
            logger.error(traceback.format_exc())
            raise
            
    async def create_backup(
        self,
        include_files: bool = True,
        upload_to_s3: bool = False,
        s3_bucket: Optional[str] = None,
        s3_prefix: str = "job-scraper-backups/",
        password_protect: bool = False,
        password: Optional[str] = None,
    ) -> str:
        """
        Create a full backup of the job data.

        Args:
            include_files: Whether to include local files
            upload_to_s3: Whether to upload to S3
            s3_bucket: S3 bucket name
            s3_prefix: S3 key prefix
            password_protect: Whether to password-protect the backup
            password: Password for the backup

        Returns:
            Path to the backup file
        """
        timestamp = dt.now().strftime("%Y%m%d_%H%M%S")
        backup_filename = f"job_backup_{timestamp}.zip"
        backup_path = self.backup_dir / backup_filename
        
        # Create a temporary directory for the backup
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_dir_path = Path(temp_dir)
            
            # Export database data if connected
            db_export_path = None
            if self.db_manager and self.db_manager.is_connected:
                logger.info("Exporting database for backup")
                db_dump_file = temp_dir_path / "db_export.json"
                
                # Export all data from database
                jobs = await self._export_from_db(None, 0)
                
                # Write to JSON file
                async with aiofiles.open(db_dump_file, "w", encoding="utf-8") as f:
                    await f.write(json.dumps(jobs, ensure_ascii=False, indent=2))
                
                logger.info(f"Database exported: {len(jobs)} records")
                db_export_path = db_dump_file
            
            # Include local files if requested
            if include_files:
                logger.info("Including local files in backup")
                # Copy raw data files
                if (self.data_dir / "raw_data").exists():
                    raw_data_dir = temp_dir_path / "raw_data"
                    raw_data_dir.mkdir(exist_ok=True)
                    for file in (self.data_dir / "raw_data").glob("*.json"):
                        shutil.copy(file, raw_data_dir)
                
                # Copy processed data files
                if (self.data_dir / "processed_data").exists():
                    processed_data_dir = temp_dir_path / "processed_data"
                    processed_data_dir.mkdir(exist_ok=True)
                    for file in (self.data_dir / "processed_data").glob("*.*"):
                        shutil.copy(file, processed_data_dir)
            
            # Save backup metadata
            metadata = {
                "backup_date": dt.now().isoformat(),
                "backup_type": "full" if include_files else "database_only",
                "db_included": bool(db_export_path),
                "files_included": include_files,
            }
            
            # Write metadata file
            with open(temp_dir_path / "backup_metadata.json", "w", encoding="utf-8") as f:
                json.dump(metadata, f, indent=2)
            
            # Create zip archive
            logger.info(f"Creating backup archive: {backup_path}")
            
            # Use appropriate ZIP creation method based on password protection
            if password_protect and password:
                # Use external tool or library for password protection
                # This is a simplified version - in production you might use a more secure method
                import zipfile
                with zipfile.ZipFile(backup_path, "w", zipfile.ZIP_DEFLATED) as zipf:
                    for root, _, files in os.walk(temp_dir_path):
                        for file in files:
                            file_path = os.path.join(root, file)
                            arcname = os.path.relpath(file_path, temp_dir_path)
                            zipf.write(file_path, arcname)
                # Note: Simple password protection is not implemented here
                # For real password protection, consider using pyzipper or another library
            else:
                # Standard zip without password
                with zipfile.ZipFile(backup_path, "w", zipfile.ZIP_DEFLATED) as zipf:
                    for root, _, files in os.walk(temp_dir_path):
                        for file in files:
                            file_path = os.path.join(root, file)
                            arcname = os.path.relpath(file_path, temp_dir_path)
                            zipf.write(file_path, arcname)
        
        # Upload to S3 if requested
        if upload_to_s3 and s3_bucket:
            try:
                s3_client = boto3.client("s3")
                s3_key = f"{s3_prefix.rstrip('/')}/{backup_filename}"
                
                logger.info(f"Uploading backup to S3: {s3_bucket}/{s3_key}")
                s3_client.upload_file(str(backup_path), s3_bucket, s3_key)
                logger.info("S3 upload completed successfully")
                
                # Add S3 location to metadata
                s3_location = f"s3://{s3_bucket}/{s3_key}"
                
                # Optionally add presigned URL
                # url = s3_client.generate_presigned_url(
                #     "get_object",
                #     Params={"Bucket": s3_bucket, "Key": s3_key},
                #     ExpiresIn=86400,  # 24 hours
                # )
                
            except Exception as e:
                logger.error(f"Error uploading to S3: {str(e)}")
        
        self.metrics["backups"] += 1
        self.metrics["last_backup"] = dt.now().isoformat()
        
        logger.info(f"Backup created successfully: {backup_path}")
        return str(backup_path)

    async def restore_backup(
        self,
        backup_file: str,
        restore_db: bool = True,
        restore_files: bool = True,
        password: Optional[str] = None,
    ) -> Dict[str, Any]:
        """
        Restore data from a backup file.

        Args:
            backup_file: Path to the backup file
            restore_db: Whether to restore database
            restore_files: Whether to restore local files
            password: Password for encrypted backups

        Returns:
            Dictionary with restore statistics
        """
        backup_path = Path(backup_file)
        if not backup_path.exists():
            raise FileNotFoundError(f"Backup file not found: {backup_path}")
        
        # Create a temporary directory for the restore
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_dir_path = Path(temp_dir)
            
            # Extract the backup
            logger.info(f"Extracting backup: {backup_path}")
            try:
                with zipfile.ZipFile(backup_path, "r") as zipf:
                    # Check if password protected
                    if zipf.testzip() is not None and password:
                        # In a real implementation, you would handle password extraction here
                        # Simple ZipFile doesn't support password protection for extraction
                        raise NotImplementedError("Password-protected ZIP extraction not implemented")
                    
                    # Extract all files
                    zipf.extractall(temp_dir_path)
            except zipfile.BadZipFile:
                raise ValueError(f"Invalid backup file: {backup_path}")
            
            # Check backup metadata
            metadata_file = temp_dir_path / "backup_metadata.json"
            if not metadata_file.exists():
                raise ValueError(f"Invalid backup: missing metadata file")
            
            with open(metadata_file, "r", encoding="utf-8") as f:
                metadata = json.load(f)
            
            logger.info(f"Backup metadata: {metadata}")
            
            stats = {"restored_db": False, "restored_files": False}
            
            # Restore database if requested
            if restore_db and metadata.get("db_included") and self.db_manager:
                db_export_file = temp_dir_path / "db_export.json"
                if db_export_file.exists():
                    logger.info("Restoring database from backup")
                    with open(db_export_file, "r", encoding="utf-8") as f:
                        jobs = json.load(f)
                    
                    # Import the jobs to database
                    if jobs:
                        import_stats = await self._store_imported_data(
                            jobs, update_existing=True, batch_size=1000
                        )
                        stats["restored_db"] = True
                        stats["db_records"] = import_stats.get("imported", 0)
                        logger.info(f"Database restored: {import_stats}")
            
            # Restore files if requested
            if restore_files and metadata.get("files_included"):
                logger.info("Restoring local files from backup")
                
                # Restore raw data files
                raw_data_dir = temp_dir_path / "raw_data"
                if raw_data_dir.exists():
                    target_dir = self.data_dir / "raw_data"
                    target_dir.mkdir(exist_ok=True, parents=True)
                    for file in raw_data_dir.glob("*.*"):
                        shutil.copy(file, target_dir)
                
                # Restore processed data files
                processed_data_dir = temp_dir_path / "processed_data"
                if processed_data_dir.exists():
                    target_dir = self.data_dir / "processed_data"
                    target_dir.mkdir(exist_ok=True, parents=True)
                    for file in processed_data_dir.glob("*.*"):
                        shutil.copy(file, target_dir)
                
                stats["restored_files"] = True
        
        self.metrics["restores"] += 1
        self.metrics["last_restore"] = dt.now().isoformat()
        
        logger.info(f"Restore completed successfully: {stats}")
        return stats

    async def list_backups(self, include_s3: bool = False, s3_bucket: Optional[str] = None, s3_prefix: str = "job-scraper-backups/") -> List[Dict[str, Any]]:
        """
        List available backups.

        Args:
            include_s3: Whether to include S3 backups
            s3_bucket: S3 bucket name
            s3_prefix: S3 key prefix

        Returns:
            List of backup information dictionaries
        """
        backups = []
        
        # List local backups
        if self.backup_dir.exists():
            for file in self.backup_dir.glob("job_backup_*.zip"):
                try:
                    size_bytes = file.stat().st_size
                    created_at = dt.fromtimestamp(file.stat().st_ctime)
                    
                    # Try to extract metadata (simplified for performance)
                    metadata = {}
                    try:
                        with zipfile.ZipFile(file, "r") as zipf:
                            if "backup_metadata.json" in zipf.namelist():
                                with zipf.open("backup_metadata.json") as meta_file:
                                    metadata = json.load(meta_file)
                    except Exception:
                        pass
                    
                    backups.append({
                        "filename": file.name,
                        "path": str(file),
                        "size_bytes": size_bytes,
                        "size_mb": round(size_bytes / (1024 * 1024), 2),
                        "created_at": created_at.isoformat(),
                        "location": "local",
                        "metadata": metadata
                    })
                except Exception as e:
                    logger.warning(f"Error processing backup file {file}: {str(e)}")
        
        # List S3 backups if requested
        if include_s3 and s3_bucket:
            try:
                s3_client = boto3.client("s3")
                paginator = s3_client.get_paginator("list_objects_v2")
                
                for page in paginator.paginate(Bucket=s3_bucket, Prefix=s3_prefix):
                    if "Contents" in page:
                        for obj in page["Contents"]:
                            if obj["Key"].endswith(".zip") and "job_backup_" in obj["Key"]:
                                filename = os.path.basename(obj["Key"])
                                backups.append({
                                    "filename": filename,
                                    "path": f"s3://{s3_bucket}/{obj['Key']}",
                                    "size_bytes": obj["Size"],
                                    "size_mb": round(obj["Size"] / (1024 * 1024), 2),
                                    "created_at": obj["LastModified"].isoformat(),
                                    "location": "s3"
                                })
            except Exception as e:
                logger.error(f"Error listing S3 backups: {str(e)}")
        
        # Sort by creation date (newest first)
        backups.sort(key=lambda x: x["created_at"], reverse=True)
        
        return backups

    def get_metrics(self) -> Dict[str, Any]:
        """
        Get data manager metrics.

        Returns:
            Dictionary with metrics data
        """
        return self.metrics.copy()

    def list_backups_sync(self, include_s3: bool = False, s3_bucket: Optional[str] = None, s3_prefix: str = "job-scraper-backups/") -> List[Dict[str, Any]]:
        """
        Synchronous version of list_backups.
        
        Lists available backup files in the backup directory and optionally S3.
        
        Args:
            include_s3: Whether to include S3 backups in the listing
            s3_bucket: S3 bucket name to check for backups
            s3_prefix: Prefix for S3 objects
            
        Returns:
            List of backup information dictionaries
        """
        # List backups from backup directory
        backups = []
        
        try:
            backup_dir = Path(self.backup_dir)
            if backup_dir.exists():
                for file in backup_dir.glob("job_backup_*.zip"):
                    stats = file.stat()
                    
                    # Try to extract date from filename
                    try:
                        date_str = file.stem.split('_')[2]
                        date = dt.strptime(date_str, '%Y%m%d%H%M%S')
                        date_str = date.isoformat()
                    except (IndexError, ValueError):
                        date_str = dt.fromtimestamp(stats.st_mtime).isoformat()
                    
                    backups.append({
                        "filename": file.name,
                        "path": str(file),
                        "size_bytes": stats.st_size,
                        "size_mb": round(stats.st_size / (1024 * 1024), 2),
                        "created_at": date_str,
                        "location": "local"
                    })
        except Exception as e:
            logger.error(f"Error listing local backups: {str(e)}")
        
        # List S3 backups if requested
        if include_s3 and s3_bucket:
            try:
                import boto3
                s3_client = boto3.client("s3")
                paginator = s3_client.get_paginator("list_objects_v2")
                
                for page in paginator.paginate(Bucket=s3_bucket, Prefix=s3_prefix):
                    if "Contents" in page:
                        for obj in page["Contents"]:
                            if obj["Key"].endswith(".zip") and "job_backup_" in obj["Key"]:
                                filename = os.path.basename(obj["Key"])
                                backups.append({
                                    "filename": filename,
                                    "path": f"s3://{s3_bucket}/{obj['Key']}",
                                    "size_bytes": obj["Size"],
                                    "size_mb": round(obj["Size"] / (1024 * 1024), 2),
                                    "created_at": obj["LastModified"].isoformat(),
                                    "location": "s3"
                                })
            except Exception as e:
                logger.error(f"Error listing S3 backups: {str(e)}")
        
        # Sort by creation date (newest first)
        backups.sort(key=lambda x: x["created_at"], reverse=True)
        
        return backups

    # Private methods

    async def _export_from_db(self, filters: Optional[Dict[str, Any]], limit: int) -> List[Dict[str, Any]]:
        """Export jobs from the database with optional filtering."""
        if not self.db_manager or not self.db_manager.is_connected:
            logger.warning("Database not connected for export")
            return []
        
        async with self.db_manager.pool.acquire() as conn:
            # Build query
            query = f"SELECT * FROM {self.db_manager.schema}.jobs"
            params = []
            
            # Add filtering
            if filters:
                where_clauses = []
                for i, (key, value) in enumerate(filters.items()):
                    if key == 'activation_time_from':
                        where_clauses.append(f"activation_time >= ${i+1}")
                        params.append(value)
                    elif key == 'activation_time_to':
                        where_clauses.append(f"activation_time <= ${i+1}")
                        params.append(value)
                    elif key == 'company_id':
                        where_clauses.append(f"company_id = ${i+1}")
                        params.append(value)
                    elif key == 'batch_id':
                        where_clauses.append(f"batch_id = ${i+1}")
                        params.append(value)
                    # Add more filters as needed
                
                if where_clauses:
                    query += " WHERE " + " AND ".join(where_clauses)
            
            # Add limit if specified
            if limit > 0:
                query += f" LIMIT {limit}"
            
            # Execute query
            records = await conn.fetch(query, *params)
            
            # Convert to dictionaries
            return [dict(record) for record in records]
    
    async def _load_from_files(self) -> List[Dict[str, Any]]:
        """Load job data from local files."""
        all_jobs = []
        
        # Try to load from raw data JSON files
        raw_data_dir = self.data_dir / "raw_data"
        if raw_data_dir.exists():
            for json_file in raw_data_dir.glob("*.json"):
                try:
                    with open(json_file, "r", encoding="utf-8") as f:
                        jobs = json.load(f)
                    if isinstance(jobs, list):
                        all_jobs.extend(jobs)
                except Exception as e:
                    logger.warning(f"Error loading file {json_file}: {str(e)}")
        
        # If no raw data, try processed data
        if not all_jobs:
            processed_dir = self.data_dir / "processed_data"
            if processed_dir.exists():
                # Try parquet files first
                for parquet_file in processed_dir.glob("*.parquet"):
                    try:
                        df = pd.read_parquet(parquet_file)
                        jobs = df.to_dict(orient="records")
                        all_jobs.extend(jobs)
                    except Exception as e:
                        logger.warning(f"Error loading file {parquet_file}: {str(e)}")
                
                # If still empty, try CSV files
                if not all_jobs:
                    for csv_file in processed_dir.glob("*.csv"):
                        try:
                            df = pd.read_csv(csv_file)
                            jobs = df.to_dict(orient="records")
                            all_jobs.extend(jobs)
                        except Exception as e:
                            logger.warning(f"Error loading file {csv_file}: {str(e)}")
        
        # Deduplicate based on 'id' field
        deduplicated = {}
        for job in all_jobs:
            if "id" in job:
                deduplicated[job["id"]] = job
        
        return list(deduplicated.values())
    
    async def _export_json(self, jobs: List[Dict[str, Any]], compress: bool) -> str:
        """Export data to JSON format."""
        # Create a temporary file
        with tempfile.NamedTemporaryFile(delete=False, suffix=".json") as temp:
            temp_path = temp.name
        
        # Write data to the temporary file
        async with aiofiles.open(temp_path, "w", encoding="utf-8") as f:
            await f.write(json.dumps(jobs, ensure_ascii=False, indent=2))
        
        # Compress if requested
        if compress:
            zip_path = f"{temp_path}.zip"
            with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
                zipf.write(temp_path, os.path.basename(temp_path))
            os.remove(temp_path)
            return zip_path
        
        return temp_path
    
    async def _export_csv(self, jobs: List[Dict[str, Any]], compress: bool) -> str:
        """Export data to CSV format."""
        # Create a temporary file
        with tempfile.NamedTemporaryFile(delete=False, suffix=".csv") as temp:
            temp_path = temp.name
        
        # Convert to DataFrame and write to CSV
        df = pd.DataFrame(jobs)
        df.to_csv(temp_path, index=False, encoding="utf-8")
        
        # Compress if requested
        if compress:
            zip_path = f"{temp_path}.zip"
            with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
                zipf.write(temp_path, os.path.basename(temp_path))
            os.remove(temp_path)
            return zip_path
        
        return temp_path
    
    async def _export_parquet(self, jobs: List[Dict[str, Any]], compress: bool) -> str:
        """Export data to Parquet format."""
        # Create a temporary file
        with tempfile.NamedTemporaryFile(delete=False, suffix=".parquet") as temp:
            temp_path = temp.name
        
        # Convert to DataFrame and write to Parquet
        df = pd.DataFrame(jobs)
        df.to_parquet(temp_path, index=False)
        
        # Compress if requested
        if compress:
            zip_path = f"{temp_path}.zip"
            with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as zipf:
                zipf.write(temp_path, os.path.basename(temp_path))
            os.remove(temp_path)
            return zip_path
        
        return temp_path
    
    async def _import_json(self, file_path: Path, is_compressed: bool) -> List[Dict[str, Any]]:
        """Import data from JSON file."""
        if is_compressed:
            # Extract the JSON file from the ZIP
            with tempfile.TemporaryDirectory() as temp_dir:
                with zipfile.ZipFile(file_path, "r") as zipf:
                    # Find the first JSON file
                    json_files = [f for f in zipf.namelist() if f.endswith(".json")]
                    if not json_files:
                        raise ValueError("No JSON file found in the ZIP archive")
                    
                    # Extract the first JSON file
                    zipf.extract(json_files[0], temp_dir)
                    extracted_path = os.path.join(temp_dir, json_files[0])
                    
                    # Read the JSON file
                    with open(extracted_path, "r", encoding="utf-8") as f:
                        return json.load(f)
        else:
            # Read the JSON file directly
            with open(file_path, "r", encoding="utf-8") as f:
                return json.load(f)
    
    async def _import_csv(self, file_path: Path, is_compressed: bool) -> List[Dict[str, Any]]:
        """Import data from CSV file."""
        if is_compressed:
            # Extract the CSV file from the ZIP
            with tempfile.TemporaryDirectory() as temp_dir:
                with zipfile.ZipFile(file_path, "r") as zipf:
                    # Find the first CSV file
                    csv_files = [f for f in zipf.namelist() if f.endswith(".csv")]
                    if not csv_files:
                        raise ValueError("No CSV file found in the ZIP archive")
                    
                    # Extract the first CSV file
                    zipf.extract(csv_files[0], temp_dir)
                    extracted_path = os.path.join(temp_dir, csv_files[0])
                    
                    # Read the CSV file
                    df = pd.read_csv(extracted_path, encoding="utf-8")
                    return df.to_dict(orient="records")
        else:
            # Read the CSV file directly
            df = pd.read_csv(file_path, encoding="utf-8")
            return df.to_dict(orient="records")
    
    async def _import_parquet(self, file_path: Path, is_compressed: bool) -> List[Dict[str, Any]]:
        """Import data from Parquet file."""
        if is_compressed:
            # Extract the Parquet file from the ZIP
            with tempfile.TemporaryDirectory() as temp_dir:
                with zipfile.ZipFile(file_path, "r") as zipf:
                    # Find the first Parquet file
                    parquet_files = [f for f in zipf.namelist() if f.endswith(".parquet")]
                    if not parquet_files:
                        raise ValueError("No Parquet file found in the ZIP archive")
                    
                    # Extract the first Parquet file
                    zipf.extract(parquet_files[0], temp_dir)
                    extracted_path = os.path.join(temp_dir, parquet_files[0])
                    
                    # Read the Parquet file
                    df = pd.read_parquet(extracted_path)
                    return df.to_dict(orient="records")
        else:
            # Read the Parquet file directly
            df = pd.read_parquet(file_path)
            return df.to_dict(orient="records")
    
    def _validate_imported_jobs(self, jobs: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """
        Validate and normalize imported job data.
        
        This ensures imported data matches the expected schema and types.
        """
        validated = []
        skipped = 0
        
        for job in jobs:
            # Check for required fields
            if "id" not in job:
                skipped += 1
                continue
            
            # Normalize fields (similar to _clean_job_data in JobScraper)
            cleaned_job = job.copy()
            
            # Ensure required fields
            if "title" not in cleaned_job:
                cleaned_job["title"] = "Untitled Job"
            
            # Normalize date fields
            if "activation_time" in cleaned_job and cleaned_job["activation_time"]:
                try:
                    # Convert various date formats
                    if isinstance(cleaned_job["activation_time"], str):
                        # Try different datetime formats
                        formats = [
                            "%Y-%m-%dT%H:%M:%S.%fZ",
                            "%Y-%m-%dT%H:%M:%SZ",
                            "%Y-%m-%d %H:%M:%S",
                            "%Y-%m-%d",
                        ]
                        
                        for fmt in formats:
                            try:
                                dt = dt.strptime(cleaned_job["activation_time"], fmt)
                                cleaned_job["activation_time"] = dt
                                break
                            except ValueError:
                                continue
                        
                        # If parsing still failed, check if it's ISO format
                        if isinstance(cleaned_job["activation_time"], str):
                            try:
                                dt = dt.fromisoformat(cleaned_job["activation_time"].replace("Z", "+00:00"))
                                cleaned_job["activation_time"] = dt
                            except ValueError:
                                # If all parsing attempts fail, keep as string
                                pass
                except Exception:
                    # Leave as-is if parsing fails
                    pass
            
            # Ensure JSON fields are properly formatted
            for field in ["locations", "work_types", "salary", "tags", "job_post_categories", "raw_data"]:
                if field in cleaned_job:
                    # If string, try to parse as JSON
                    if isinstance(cleaned_job[field], str):
                        try:
                            cleaned_job[field] = json.loads(cleaned_job[field])
                        except json.JSONDecodeError:
                            # If parsing fails, use an appropriate default
                            if field in ["locations", "work_types", "tags", "job_post_categories"]:
                                cleaned_job[field] = []
                            elif field == "salary":
                                cleaned_job[field] = {}
                            elif field == "raw_data":
                                cleaned_job[field] = {"imported": True}
            
            validated.append(cleaned_job)
        
        logger.info(f"Validation result: {len(validated)} valid, {skipped} skipped")
        return validated
    
    async def _store_imported_data(
        self,
        jobs: List[Dict[str, Any]],
        update_existing: bool,
        batch_size: int
    ) -> Dict[str, Any]:
        """
        Store imported data in the database or local files.
        
        Returns statistics about the import operation.
        """
        stats = {"total": len(jobs), "imported": 0, "errors": 0}
        
        # If DB is connected, use it
        if self.db_manager and self.db_manager.is_connected:
            logger.info(f"Storing {len(jobs)} jobs in database")
            try:
                # Generate a batch ID for this import
                batch_id = f"import_{dt.now().strftime('%Y%m%d_%H%M%S')}"
                batch_date = dt.now()
                
                # Process in batches
                for i in range(0, len(jobs), batch_size):
                    batch = jobs[i:i + batch_size]
                    
                    try:
                        # Insert into database
                        inserted = await self.db_manager.insert_jobs(batch, batch_id)
                        stats["imported"] += inserted
                    except Exception as e:
                        logger.error(f"Error storing batch: {str(e)}")
                        stats["errors"] += 1
                
                logger.info(f"Database import completed: {stats['imported']} jobs imported")
            except Exception as e:
                logger.error(f"Error storing in database: {str(e)}")
                logger.error(traceback.format_exc())
                stats["errors"] += 1
        
        # Always save to local files as backup
        try:
            # Save to JSON file
            timestamp = dt.now().strftime("%Y%m%d_%H%M%S")
            filename = f"import_{timestamp}.json"
            file_path = self.data_dir / "imports" / filename
            file_path.parent.mkdir(exist_ok=True, parents=True)
            
            with open(file_path, "w", encoding="utf-8") as f:
                json.dump(jobs, f, ensure_ascii=False, indent=2)
            
            logger.info(f"Saved import to file: {file_path}")
            stats["file_path"] = str(file_path)
            
            # Also save to processed directory in both formats
            processed_dir = self.data_dir / "processed_data"
            processed_dir.mkdir(exist_ok=True, parents=True)
            
            df = pd.DataFrame(jobs)
            
            # Save as Parquet
            parquet_path = processed_dir / f"import_{timestamp}.parquet"
            df.to_parquet(parquet_path, index=False)
            
            # Save as CSV
            csv_path = processed_dir / f"import_{timestamp}.csv"
            df.to_csv(csv_path, index=False, encoding="utf-8")
            
        except Exception as e:
            logger.error(f"Error saving to files: {str(e)}")
            logger.error(traceback.format_exc())
            stats["errors"] += 1
        
        return stats 