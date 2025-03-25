"""
Unit tests for the database manager.
"""

import unittest
import os
import sys
from unittest.mock import patch, MagicMock
import tempfile
import yaml

# Add the parent directory to sys.path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '../../')))

# Assuming we have a DatabaseManager class in app.db.manager
from app.db.manager import DatabaseManager


class TestDatabaseManager(unittest.TestCase):
    """Test cases for the database manager."""
    
    def setUp(self):
        """Set up test environment."""
        # Create a temporary config file
        self.config_file = tempfile.NamedTemporaryFile(suffix='.yaml', delete=False)
        self.config_path = self.config_file.name
        
        # Write test configuration
        config = {
            'database': {
                'url': 'sqlite:///:memory:',
                'pool_size': 5,
                'max_overflow': 10,
                'pool_recycle': 3600,
                'echo': False
            }
        }
        
        yaml.dump(config, self.config_file)
        self.config_file.close()
        
        # Create database manager
        self.db_manager = DatabaseManager(config_path=self.config_path)
    
    def tearDown(self):
        """Clean up after tests."""
        # Remove temporary config file
        os.unlink(self.config_path)
        
        # Close database connections
        if hasattr(self, 'db_manager'):
            self.db_manager.close()
    
    def test_init_with_config_file(self):
        """Test initialization with config file."""
        # Check if engine was created
        self.assertIsNotNone(self.db_manager.engine)
        self.assertIsNotNone(self.db_manager.session_factory)
        self.assertEqual(str(self.db_manager.engine.url), 'sqlite:///:memory:')
    
    @patch('app.db.manager.create_engine')
    def test_init_with_env_vars(self, mock_create_engine):
        """Test initialization with environment variables."""
        # Mock environment variables
        with patch.dict('os.environ', {'DATABASE_URL': 'postgresql://user:pass@localhost/testdb'}):
            db_manager = DatabaseManager()
            
            # Check if environment variable was used
            mock_create_engine.assert_called_once()
            call_args = mock_create_engine.call_args[0]
            self.assertEqual(call_args[0], 'postgresql://user:pass@localhost/testdb')
    
    def test_get_session(self):
        """Test getting a session."""
        # Get session
        session = self.db_manager.get_session()
        
        # Check if session was created
        self.assertIsNotNone(session)
        
        # Clean up
        session.close()
    
    def test_create_tables(self):
        """Test creating database tables."""
        # Mock Base.metadata.create_all
        with patch('app.db.models.Base.metadata.create_all') as mock_create_all:
            self.db_manager.create_tables()
            
            # Check if create_all was called
            mock_create_all.assert_called_once_with(self.db_manager.engine)
    
    def test_drop_tables(self):
        """Test dropping database tables."""
        # Mock Base.metadata.drop_all
        with patch('app.db.models.Base.metadata.drop_all') as mock_drop_all:
            self.db_manager.drop_tables()
            
            # Check if drop_all was called
            mock_drop_all.assert_called_once_with(self.db_manager.engine)
    
    def test_health_check(self):
        """Test database health check."""
        # Mock engine.connect
        with patch.object(self.db_manager.engine, 'connect') as mock_connect:
            mock_connection = MagicMock()
            mock_connect.return_value.__enter__.return_value = mock_connection
            
            # Mock execute method
            mock_result = MagicMock()
            mock_result.scalar.return_value = 'SQLite mock version'
            mock_connection.execute.return_value = mock_result
            
            # Call health check
            status, version = self.db_manager.health_check()
            
            # Check results
            self.assertTrue(status)
            self.assertEqual(version, 'SQLite mock version')
    
    def test_close(self):
        """Test closing database connections."""
        # Mock engine.dispose
        with patch.object(self.db_manager.engine, 'dispose') as mock_dispose:
            self.db_manager.close()
            
            # Check if dispose was called
            mock_dispose.assert_called_once()
    
    @patch('app.db.manager.create_engine')
    def test_connection_error_handling(self, mock_create_engine):
        """Test handling connection errors."""
        # Mock create_engine to raise an exception
        mock_create_engine.side_effect = Exception("Connection error")
        
        # Check if exception is caught
        with self.assertRaises(Exception):
            DatabaseManager(config_path=self.config_path)


if __name__ == '__main__':
    unittest.main() 