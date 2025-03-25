import os
import sys
from pathlib import Path
from typing import Optional, Dict, Any

from dotenv import load_dotenv

# Add the project root to path
project_root = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(project_root))

# Load environment variables from .env file if it exists
env_path = project_root / '.env'
load_dotenv(dotenv_path=env_path)

# Import the app factory
from src.app import create_app

def get_config() -> Dict[str, Any]:
    """
    Get configuration from environment variables.
    
    Returns:
        Dictionary with configuration values
    """
    config = {
        'HOST': os.environ.get('FLASK_HOST', '0.0.0.0'),
        'PORT': int(os.environ.get('FLASK_PORT', 5000)),
        'DEBUG': os.environ.get('FLASK_DEBUG', 'False').lower() in ('true', '1', 't'),
        'ENV': os.environ.get('FLASK_ENV', 'production'),
        'CONFIG_PATH': os.environ.get('CONFIG_PATH', 'config/app_config.yaml'),
        'DB_CONNECTION_STRING': get_db_connection_string(),
        'TESTING': False
    }
    
    return config

def get_db_connection_string() -> str:
    """
    Construct database connection string from environment variables.
    
    Returns:
        PostgreSQL connection string
    """
    # Check if full connection string is provided
    connection_string = os.environ.get('DATABASE_URL')
    if connection_string:
        return connection_string
        
    # Otherwise, build from individual components
    host = os.environ.get('POSTGRES_HOST', 'localhost')
    port = os.environ.get('POSTGRES_PORT', '5432')
    db = os.environ.get('POSTGRES_DB', 'jobsdb')
    
    # Try to get password from file first, then from environment
    user = os.environ.get('POSTGRES_USER', 'jobuser')
    password_file = os.environ.get('POSTGRES_PASSWORD_FILE')
    
    if password_file and os.path.exists(password_file):
        with open(password_file, 'r') as f:
            password = f.read().strip()
    else:
        password = os.environ.get('POSTGRES_PASSWORD', 'devpassword')
        
    # Construct connection string
    return f"postgresql://{user}:{password}@{host}:{port}/{db}"

def main():
    """
    Run the Flask application.
    """
    # Get configuration
    config = get_config()
    
    # Create the application
    app = create_app(
        config_path=config['CONFIG_PATH'],
        db_connection_string=config['DB_CONNECTION_STRING'],
        testing=config['TESTING']
    )
    
    # Run the application
    app.run(
        host=config['HOST'],
        port=config['PORT'],
        debug=config['DEBUG']
    )

if __name__ == '__main__':
    main() 