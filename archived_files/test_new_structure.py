#!/usr/bin/env python3
"""
Test script to verify the new application structure works correctly.
"""

import sys
import logging
from app import create_app

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

def main():
    """Test the application factory and routes"""
    logger.info("Testing application with new structure...")
    
    # Create the Flask app using the application factory
    app = create_app(config_path="config/api_config.yaml")
    
    # Run the app in debug mode
    logger.info("Starting application...")
    app.run(host="0.0.0.0", port=5000, debug=True)

if __name__ == "__main__":
    main() 