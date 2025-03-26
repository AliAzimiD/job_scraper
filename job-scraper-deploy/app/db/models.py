"""
Database models for the Job Scraper application.
"""
import datetime
from sqlalchemy import Column, Integer, String, DateTime, Boolean, Text, ForeignKey

from app.db import Base

class Job(Base):
    """Job model representing a job listing."""
    
    __tablename__ = 'jobs'
    
    id = Column(Integer, primary_key=True)
    title = Column(String(255), nullable=False)
    company = Column(String(255), nullable=False)
    location = Column(String(255))
    description = Column(Text)
    url = Column(String(512), unique=True, nullable=False)
    posted_date = Column(DateTime)
    found_date = Column(DateTime, default=datetime.datetime.utcnow)
    source = Column(String(100))
    salary_min = Column(Integer)
    salary_max = Column(Integer)
    salary_currency = Column(String(10))
    is_remote = Column(Boolean, default=False)
    is_active = Column(Boolean, default=True)
    
    def __repr__(self):
        return f"<Job(id={self.id}, title='{self.title}', company='{self.company}')>"
    
    def to_dict(self):
        """Convert the job to a dictionary."""
        return {
            "id": self.id,
            "title": self.title,
            "company": self.company,
            "location": self.location,
            "url": self.url,
            "posted_date": self.posted_date.isoformat() if self.posted_date else None,
            "found_date": self.found_date.isoformat() if self.found_date else None,
            "source": self.source,
            "salary_min": self.salary_min,
            "salary_max": self.salary_max,
            "salary_currency": self.salary_currency,
            "is_remote": self.is_remote,
            "is_active": self.is_active
        }

class ScraperRun(Base):
    """Model to track scraper runs."""
    
    __tablename__ = 'scraper_runs'
    
    id = Column(Integer, primary_key=True)
    source = Column(String(100), nullable=False)
    start_time = Column(DateTime, default=datetime.datetime.utcnow)
    end_time = Column(DateTime)
    jobs_found = Column(Integer, default=0)
    jobs_added = Column(Integer, default=0)
    status = Column(String(20), default='running')  # running, completed, failed
    error = Column(Text)
    
    def __repr__(self):
        return f"<ScraperRun(id={self.id}, source='{self.source}', status='{self.status}')>"
    
    def to_dict(self):
        """Convert the scraper run to a dictionary."""
        return {
            "id": self.id,
            "source": self.source,
            "start_time": self.start_time.isoformat() if self.start_time else None,
            "end_time": self.end_time.isoformat() if self.end_time else None,
            "jobs_found": self.jobs_found,
            "jobs_added": self.jobs_added,
            "status": self.status,
            "error": self.error
        } 