"""
Unit tests for the Flask application factory.
"""

import unittest
from unittest.mock import patch, MagicMock
import os
import sys
import tempfile
import yaml

# Add the parent directory to sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../')))

from app import create_app


class TestAppFactory(unittest.TestCase):
    """Test cases for the application factory."""
    
    def setUp(self):
        """Set up test environment."""
        # Create temporary config file
        self.config_file = tempfile.NamedTemporaryFile(suffix='.yaml', delete=False)
        self.config_path = self.config_file.name
        
        # Write test configuration
        config = {
            'app': {
                'name': 'Job Scraper Test',
                'debug': True,
                'environment': 'testing',
                'secret_key': 'test_secret_key'
            },
            'database': {
                'url': 'sqlite:///:memory:'
            },
            'redis': {
                'host': 'localhost',
                'port': 6379,
                'db': 0
            }
        }
        
        yaml.dump(config, self.config_file)
        self.config_file.close()
    
    def tearDown(self):
        """Clean up after tests."""
        # Remove temporary config file
        os.unlink(self.config_path)
    
    def test_create_app_with_config_file(self):
        """Test creating app with configuration file."""
        app = create_app(config_path=self.config_path)
        
        # Check app instance
        self.assertIsNotNone(app)
        self.assertEqual(app.debug, True)
        self.assertEqual(app.config['SECRET_KEY'], 'test_secret_key')
        self.assertEqual(app.config['ENVIRONMENT'], 'testing')
        
        # Check blueprints are registered
        self.assertIn('static', app.blueprints)
    
    @patch('app.os.environ')
    def test_create_app_with_env_vars(self, mock_environ):
        """Test creating app with environment variables."""
        # Set environment variables
        mock_environ.get.side_effect = lambda key, default=None: {
            'FLASK_DEBUG': 'True',
            'SECRET_KEY': 'env_secret_key',
            'ENVIRONMENT': 'production',
            'DATABASE_URL': 'postgresql://user:pass@localhost/testdb',
            'REDIS_HOST': 'redis.example.com',
            'REDIS_PORT': '6380'
        }.get(key, default)
        
        # Create app without specifying config path
        app = create_app()
        
        # Check app instance
        self.assertIsNotNone(app)
        self.assertEqual(app.debug, True)
        self.assertEqual(app.config['SECRET_KEY'], 'env_secret_key')
        self.assertEqual(app.config['ENVIRONMENT'], 'production')
        
        # Check database config
        self.assertEqual(app.config['DATABASE_URL'], 'postgresql://user:pass@localhost/testdb')
    
    @patch('app.load_db')
    @patch('app.setup_monitoring')
    def test_create_app_initializes_components(self, mock_setup_monitoring, mock_load_db):
        """Test app factory initializes all components."""
        app = create_app(config_path=self.config_path)
        
        # Check component initialization
        mock_load_db.assert_called_once()
        mock_setup_monitoring.assert_called_once()
    
    def test_create_app_handles_missing_config(self):
        """Test app creation with nonexistent config file."""
        # Create app with nonexistent config file
        app = create_app(config_path='nonexistent_config.yaml')
        
        # App should still be created with default config
        self.assertIsNotNone(app)
        self.assertFalse(app.debug)  # Default is False


if __name__ == '__main__':
    unittest.main() 