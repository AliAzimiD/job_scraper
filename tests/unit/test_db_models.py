"""
Unit tests for database models.
"""

import unittest
import os
import sys
from datetime import datetime
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

# Add the parent directory to sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../')))

from app.db.models import Base, Job, Tag, ScraperSearch, SearchResult, ScraperRun


class TestDatabaseModels(unittest.TestCase):
    """Test cases for database models."""
    
    def setUp(self):
        """Set up test database."""
        # Create in-memory SQLite database
        self.engine = create_engine('sqlite:///:memory:')
        
        # Create all tables
        Base.metadata.create_all(self.engine)
        
        # Create session
        Session = sessionmaker(bind=self.engine)
        self.session = Session()
    
    def tearDown(self):
        """Clean up after tests."""
        self.session.close()
        Base.metadata.drop_all(self.engine)
    
    def test_job_model(self):
        """Test Job model basic operations."""
        # Create job
        job = Job(
            source_id='test123',
            title='Python Developer',
            company='Test Company',
            location='Remote',
            description='Job description',
            url='https://example.com/job/123',
            salary_min=70000,
            salary_max=100000,
            salary_currency='USD',
            remote=True,
            job_type='Full-time',
            experience_level='Mid-level',
            posted_date=datetime.now(),
            source_website='example.com',
            still_active=True,
            metadata={'skills': ['Python', 'Flask', 'SQL']}
        )
        
        # Add job to session and commit
        self.session.add(job)
        self.session.commit()
        
        # Query job
        queried_job = self.session.query(Job).filter_by(source_id='test123').first()
        
        # Assert job was created correctly
        self.assertIsNotNone(queried_job)
        self.assertEqual(queried_job.title, 'Python Developer')
        self.assertEqual(queried_job.company, 'Test Company')
        self.assertTrue(queried_job.remote)
        self.assertEqual(queried_job.salary_currency, 'USD')
        self.assertEqual(queried_job.metadata['skills'], ['Python', 'Flask', 'SQL'])
    
    def test_job_to_dict_method(self):
        """Test Job model to_dict method."""
        # Create job
        job = Job(
            source_id='test456',
            title='Data Scientist',
            company='Another Company',
            location='New York',
            description='Job description',
            url='https://example.com/job/456',
            salary_min=90000,
            salary_max=120000,
            salary_currency='USD',
            remote=False,
            job_type='Full-time',
            experience_level='Senior',
            posted_date=datetime(2023, 1, 15),
            source_website='example.com',
            still_active=True
        )
        
        # Add job to session and commit
        self.session.add(job)
        self.session.commit()
        
        # Get dictionary representation
        job_dict = job.to_dict()
        
        # Assert dictionary contains expected fields
        self.assertEqual(job_dict['title'], 'Data Scientist')
        self.assertEqual(job_dict['company'], 'Another Company')
        self.assertEqual(job_dict['location'], 'New York')
        self.assertEqual(job_dict['salary_min'], 90000)
        self.assertEqual(job_dict['posted_date'], '2023-01-15T00:00:00')
        self.assertTrue(job_dict['still_active'])
        self.assertEqual(job_dict['tags'], [])
    
    def test_tag_model_and_relationships(self):
        """Test Tag model and relationships."""
        # Create job
        job = Job(
            source_id='test789',
            title='DevOps Engineer',
            company='Tech Company',
            url='https://example.com/job/789',
            source_website='example.com'
        )
        
        # Create tags
        tag1 = Tag(name='DevOps', description='DevOps related')
        tag2 = Tag(name='AWS', description='Amazon Web Services')
        
        # Associate tags with job
        job.tags.append(tag1)
        job.tags.append(tag2)
        
        # Add to session and commit
        self.session.add_all([job, tag1, tag2])
        self.session.commit()
        
        # Query job with tags
        queried_job = self.session.query(Job).filter_by(source_id='test789').first()
        
        # Assert relationships
        self.assertEqual(len(queried_job.tags), 2)
        self.assertIn('DevOps', [tag.name for tag in queried_job.tags])
        self.assertIn('AWS', [tag.name for tag in queried_job.tags])
        
        # Query tag with jobs
        queried_tag = self.session.query(Tag).filter_by(name='DevOps').first()
        
        # Assert reverse relationship
        self.assertEqual(len(queried_tag.jobs), 1)
        self.assertEqual(queried_tag.jobs[0].title, 'DevOps Engineer')
    
    def test_scraper_search_model(self):
        """Test ScraperSearch model."""
        # Create search
        search = ScraperSearch(
            query='python developer',
            location='Remote',
            source_website='example.com',
            job_type='Full-time',
            remote_only=True,
            frequency='daily'
        )
        
        # Add to session and commit
        self.session.add(search)
        self.session.commit()
        
        # Query search
        queried_search = self.session.query(ScraperSearch).filter_by(query='python developer').first()
        
        # Assert search was created correctly
        self.assertIsNotNone(queried_search)
        self.assertEqual(queried_search.location, 'Remote')
        self.assertTrue(queried_search.remote_only)
        self.assertEqual(queried_search.frequency, 'daily')
    
    def test_scraper_run_model(self):
        """Test ScraperRun model."""
        # Create run
        run = ScraperRun(
            status='completed',
            jobs_found=50,
            jobs_added=20,
            start_time=datetime.now()
        )
        
        # Add to session and commit
        self.session.add(run)
        self.session.commit()
        
        # Query run
        queried_run = self.session.query(ScraperRun).filter_by(status='completed').first()
        
        # Assert run was created correctly
        self.assertIsNotNone(queried_run)
        self.assertEqual(queried_run.jobs_found, 50)
        self.assertEqual(queried_run.jobs_added, 20)
        self.assertIsNotNone(queried_run.run_id)
    
    def test_search_result_relationship(self):
        """Test SearchResult relationship between Job and ScraperSearch."""
        # Create job
        job = Job(
            source_id='test321',
            title='Frontend Developer',
            company='Web Company',
            url='https://example.com/job/321',
            source_website='example.com'
        )
        
        # Create search
        search = ScraperSearch(
            query='frontend developer',
            source_website='example.com'
        )
        
        # Add to session and commit
        self.session.add_all([job, search])
        self.session.commit()
        
        # Create search result
        search_result = SearchResult(
            search_id=search.id,
            job_id=job.id,
            relevance_score=0.95
        )
        
        # Add to session and commit
        self.session.add(search_result)
        self.session.commit()
        
        # Query job with searches
        queried_job = self.session.query(Job).filter_by(source_id='test321').first()
        
        # Assert relationship
        self.assertEqual(len(queried_job.searches), 1)
        self.assertEqual(queried_job.searches[0].query, 'frontend developer')
        
        # Query search with jobs
        queried_search = self.session.query(ScraperSearch).filter_by(query='frontend developer').first()
        
        # Assert reverse relationship
        self.assertEqual(len(queried_search.jobs), 1)
        self.assertEqual(queried_search.jobs[0].title, 'Frontend Developer')


if __name__ == '__main__':
    unittest.main() 