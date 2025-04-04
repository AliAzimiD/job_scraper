#!/usr/bin/env python3
"""
Script to run the Job Scraper Admin Dashboard.
This makes it easy to start the admin dashboard without remembering the exact command.
"""

import os
import sys
import uvicorn
import logging
import argparse
from pathlib import Path
import socket

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(os.path.join("logs", "admin_dashboard.log"))
    ]
)

logger = logging.getLogger("admin_dashboard")

def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(description="Run the Job Scraper Admin Dashboard")
    parser.add_argument("--host", default="0.0.0.0", help="Host address to bind to")
    parser.add_argument("--port", type=int, default=8081, help="Port to bind to")
    parser.add_argument("--reload", action="store_true", help="Enable auto-reload for development")
    return parser.parse_args()

def check_environment():
    """Check that the environment is correctly set up."""
    # Ensure we're in the project root directory
    script_path = Path(__file__).resolve()
    project_root = script_path.parent
    
    # Change to the project root directory if not already there
    if os.getcwd() != str(project_root):
        os.chdir(project_root)
        logger.info(f"Changed working directory to {project_root}")
    
    # Check for src directory
    if not os.path.isdir("src"):
        logger.error("src directory not found. Are you in the project root?")
        sys.exit(1)
    
    # Check for main module
    if not os.path.isfile(os.path.join("src", "main.py")):
        logger.error("src/main.py not found. Project structure incorrect.")
        sys.exit(1)
    
    # Check for admin modules
    admin_modules = [
        os.path.join("src", "admin_api.py"),
        os.path.join("src", "admin_routes.py"),
        os.path.join("src", "static_server.py")
    ]
    
    for module in admin_modules:
        if not os.path.isfile(module):
            logger.error(f"{module} not found. Admin dashboard may not work correctly.")
    
    # Ensure logs directory exists
    os.makedirs("logs", exist_ok=True)
    
    # Check for admin UI files
    admin_ui_path = os.path.join("public", "admin", "index.html")
    if not os.path.isfile(admin_ui_path):
        logger.warning(f"{admin_ui_path} not found. Admin UI may not be properly set up.")
        logger.info("You may need to run scripts/setup_admin.sh to set up the admin UI.")

def check_port_available(port):
    """Check if a port is available."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        try:
            s.bind(('0.0.0.0', port))
            return True
        except OSError:
            return False
            
def find_available_port(start_port=8081, max_attempts=10):
    """Find an available port starting from start_port."""
    port = start_port
    for _ in range(max_attempts):
        if check_port_available(port):
            return port
        port += 1
        logger.warning(f"Port {port-1} is in use, trying port {port}")
    
    logger.error(f"Could not find an available port after {max_attempts} attempts")
    return start_port  # Return the original port even though it's not available

def main():
    """Main function to run the admin dashboard."""
    args = parse_args()
    
    # Check environment
    check_environment()
    
    # Find an available port if the specified port is not available
    if not check_port_available(args.port):
        logger.warning(f"Port {args.port} is already in use")
        new_port = find_available_port(args.port)
        if new_port != args.port:
            logger.info(f"Using alternative port: {new_port}")
            args.port = new_port
        else:
            logger.warning(f"Could not find an available port, trying {args.port} anyway")
    
    # Log startup information
    logger.info(f"Starting Job Scraper Admin Dashboard on http://{args.host}:{args.port}/admin")
    logger.info("Press Ctrl+C to stop the server")
    
    # Show colorful startup message
    print("\033[1;34m=== Job Scraper Admin Dashboard ===\033[0m")
    print(f"\033[1;32m✓ Server starting at: \033[1;36mhttp://{args.host}:{args.port}/admin\033[0m")
    print("\033[1;33m! Press Ctrl+C to stop the server\033[0m")
    
    # Start the uvicorn server
    try:
        uvicorn.run(
            "src.main:app",
            host=args.host,
            port=args.port,
            reload=args.reload,
            log_level="info"
        )
    except Exception as e:
        logger.error(f"Error starting server: {str(e)}")
        print(f"\033[1;31mError starting server: {str(e)}\033[0m")
        sys.exit(1)

if __name__ == "__main__":
    main() 