"""
WSGI entry point for the Job Scraper application.
This file is used by Gunicorn to serve the application.
"""
import os
from app import create_app

# Create the Flask application instance
app = create_app()

if __name__ == "__main__":
    # Run the app only if this file is executed directly
    port = int(os.environ.get("PORT", 5000))
    app.run(host="0.0.0.0", port=port)
