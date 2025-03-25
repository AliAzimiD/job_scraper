#!/usr/bin/env python3
"""
Job Scraper Application

This is the main entry point for the Job Scraper application.
It creates and runs the Flask application.

Usage:
    python3 main.py [options]

Note:
    This project uses 'python3' as the standard command.
    If you encounter 'command not found' errors, please see
    PYTHON_COMMAND_GUIDE.md for troubleshooting steps.
"""

import argparse
import os
import logging
from app import create_app


def parse_args():
    """
    Parse command line arguments.
    
    Returns:
        Parsed arguments
    """
    parser = argparse.ArgumentParser(description='Job Scraper Application')
    parser.add_argument(
        '--config',
        type=str,
        default=os.environ.get('CONFIG_PATH', 'config/api_config.yaml'),
        help='Path to configuration file (default: config/api_config.yaml)'
    )
    parser.add_argument(
        '--host',
        type=str,
        default=os.environ.get('FLASK_RUN_HOST', '0.0.0.0'),
        help='Host to bind to (default: 0.0.0.0)'
    )
    parser.add_argument(
        '--port',
        type=int,
        default=int(os.environ.get('FLASK_RUN_PORT', 5000)),
        help='Port to bind to (default: 5000)'
    )
    parser.add_argument(
        '--debug',
        action='store_true',
        default=os.environ.get('FLASK_DEBUG', '0') == '1',
        help='Enable debug mode'
    )
    return parser.parse_args()


def setup_logging():
    """Set up basic logging configuration."""
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
        datefmt='%Y-%m-%d %H:%M:%S'
    )


def main():
    """Main entry point for the application."""
    # Parse command line arguments
    args = parse_args()
    
    # Set up logging
    setup_logging()
    
    # Create logger
    logger = logging.getLogger('job_scraper')
    
    # Log startup information
    logger.info(f"Starting Job Scraper application with config: {args.config}")
    logger.info(f"Debug mode: {'Enabled' if args.debug else 'Disabled'}")
    
    # Create Flask app
    app = create_app(config_path=args.config)
    
    # Run the app
    app.run(
        host=args.host,
        port=args.port,
        debug=args.debug,
        use_reloader=args.debug
    )


if __name__ == '__main__':
    main()
