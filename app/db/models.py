"""
Database models for the Job Scraper application.

This module defines the SQLAlchemy ORM models representing the database schema.
"""

import uuid
from datetime import datetime
from typing import Dict, Any, List

from sqlalchemy import Column, Integer, String, Float, Boolean, DateTime, Text, ForeignKey, Table, JSON
from sqlalchemy.orm import relationship, validates
import sqlalchemy.types as types

from app.db import Base


# Association table for many-to-many relationship between jobs and tags
job_tags = Table(
    'job_tags',
    Base.metadata,
    Column('job_id', Integer, ForeignKey('jobs.id', ondelete='CASCADE'), primary_key=True),
    Column('tag_id', Integer, ForeignKey('tags.id', ondelete='CASCADE'), primary_key=True)
)


class Job(Base):
    """Job model representing a job posting."""
    
    __tablename__ = 'jobs'
    
    id = Column(Integer, primary_key=True)
    source_id = Column(String(255), nullable=False, index=True)
    title = Column(String(255), nullable=False)
    company = Column(String(255), nullable=False)
    location = Column(String(255))
    description = Column(Text)
    url = Column(String(512), nullable=False)
    salary_min = Column(Float)
    salary_max = Column(Float)
    salary_currency = Column(String(10))
    remote = Column(Boolean, default=False)
    job_type = Column(String(50))  # full-time, part-time, contract, etc.
    experience_level = Column(String(50))  # junior, mid, senior, etc.
    posted_date = Column(DateTime)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    updated_at = Column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow, nullable=False)
    source_website = Column(String(100), nullable=False)
    still_active = Column(Boolean, default=True)
    last_check_date = Column(DateTime)
    metadata = Column(JSON)
    
    # Relationships
    tags = relationship("Tag", secondary=job_tags, back_populates="jobs")
    scraper_run_id = Column(String(36), ForeignKey('scraper_runs.run_id'))
    scraper_run = relationship("ScraperRun", back_populates="jobs")
    
    __table_args__ = (
        # Index for faster searching
        {'mysql_charset': 'utf8mb4', 'mysql_collate': 'utf8mb4_unicode_ci'}
    )
    
    @validates('url')
    def validate_url(self, key, url):
        """Validate the URL format."""
        if not url.startswith(('http://', 'https://')):
            url = 'https://' + url
        return url
    
    def to_dict(self) -> Dict[str, Any]:
        """
        Convert the job to a dictionary representation.
        
        Returns:
            Dictionary containing job data
        """
        return {
            'id': self.id,
            'source_id': self.source_id,
            'title': self.title,
            'company': self.company,
            'location': self.location,
            'description': self.description,
            'url': self.url,
            'salary_min': self.salary_min,
            'salary_max': self.salary_max,
            'salary_currency': self.salary_currency,
            'remote': self.remote,
            'job_type': self.job_type,
            'experience_level': self.experience_level,
            'posted_date': self.posted_date.isoformat() if self.posted_date else None,
            'created_at': self.created_at.isoformat() if self.created_at else None,
            'updated_at': self.updated_at.isoformat() if self.updated_at else None,
            'source_website': self.source_website,
            'still_active': self.still_active,
            'last_check_date': self.last_check_date.isoformat() if self.last_check_date else None,
            'tags': [tag.name for tag in self.tags] if self.tags else []
        }
    
    def __repr__(self) -> str:
        return f"<Job(id={self.id}, title='{self.title}', company='{self.company}')>"


class Tag(Base):
    """Tag model for categorizing jobs."""
    
    __tablename__ = 'tags'
    
    id = Column(Integer, primary_key=True)
    name = Column(String(50), nullable=False, unique=True)
    description = Column(String(255))
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    
    # Relationships
    jobs = relationship("Job", secondary=job_tags, back_populates="tags")
    
    def __repr__(self) -> str:
        return f"<Tag(id={self.id}, name='{self.name}')>"


class ScraperRun(Base):
    """Model to track scraper execution history."""
    
    __tablename__ = 'scraper_runs'
    
    id = Column(Integer, primary_key=True)
    start_time = Column(DateTime, nullable=False, default=datetime.utcnow)
    end_time = Column(DateTime)
    status = Column(String(50), nullable=False)  # running, completed, failed, cancelled
    jobs_found = Column(Integer, default=0)
    jobs_added = Column(Integer, default=0)
    error_message = Column(Text)
    run_id = Column(String(36), nullable=False, unique=True, default=lambda: str(uuid.uuid4()))
    source_website = Column(String(100))
    max_pages = Column(Integer)
    keywords = Column(String(255))
    location = Column(String(255))
    
    # Relationships
    jobs = relationship("Job", back_populates="scraper_run")
    
    __table_args__ = (
        # Index for faster querying of recent runs
        {'mysql_charset': 'utf8mb4', 'mysql_collate': 'utf8mb4_unicode_ci'}
    )
    
    def to_dict(self) -> Dict[str, Any]:
        """
        Convert the scraper run to a dictionary representation.
        
        Returns:
            Dictionary containing scraper run data
        """
        return {
            'id': self.id,
            'run_id': self.run_id,
            'start_time': self.start_time.isoformat() if self.start_time else None,
            'end_time': self.end_time.isoformat() if self.end_time else None,
            'status': self.status,
            'jobs_found': self.jobs_found,
            'jobs_added': self.jobs_added,
            'error_message': self.error_message,
            'source_website': self.source_website,
            'max_pages': self.max_pages,
            'keywords': self.keywords,
            'location': self.location
        }
    
    def __repr__(self) -> str:
        return f"<ScraperRun(id={self.id}, status='{self.status}', jobs_found={self.jobs_found})>" 