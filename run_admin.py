#!/usr/bin/env python3
"""Script to run the Job Scraper Admin Dashboard."""

import os
import sys
import uvicorn

# Create logs directory if it doesn't exist
os.makedirs("logs", exist_ok=True)

def main():
    """Run the admin dashboard."""
    print("Starting Job Scraper Admin Dashboard")
    print("Dashboard will be available at: http://localhost:8081/admin")
    
    # Run the application with uvicorn
    uvicorn.run(
        "src.main:app",
        host="0.0.0.0",
        port=8081,
        reload=True  # Enable auto-reload for development
    )

if __name__ == "__main__":
    # Add current directory to path so we can import modules
    sys.path.insert(0, os.path.abspath(os.path.dirname(__file__)))
    main() 