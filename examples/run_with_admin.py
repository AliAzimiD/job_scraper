#!/usr/bin/env python3
"""
Example script to run the Job Scraper with Admin Dashboard
"""

import os
import sys
import uvicorn

# Add the parent directory to the path so we can import the modules
parent_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, parent_dir)

from src.main import app

if __name__ == "__main__":
    print("Starting Job Scraper with Admin Dashboard")
    print("Dashboard will be available at: http://localhost:8081/admin")
    
    # Run the application with uvicorn
    uvicorn.run(
        "src.main:app",
        host="0.0.0.0",
        port=8081,
        reload=True  # Enable auto-reload for development
    ) 