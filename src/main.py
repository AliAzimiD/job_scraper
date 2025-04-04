"""Main application entry point for job scraper."""
import logging
import os
import sys
from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware

# Make sure to create logs directory
os.makedirs("logs", exist_ok=True)

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(os.path.join("logs", "scraper.log"))
    ]
)

logger = logging.getLogger(__name__)

# Create FastAPI app
app = FastAPI(title="Job Scraper API", description="API for job scraper")

# Add CORS middleware to allow requests from the admin UI
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, restrict this to your domain
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

try:
    # Import our custom modules
    from .admin_routes import add_admin_routes
    from .static_server import setup_static_files
    
    # Add admin routes
    add_admin_routes(app)
    
    # Setup static file serving
    setup_static_files(app)
    
    logger.info("Admin routes and static files successfully configured")
except ImportError as e:
    logger.error(f"Failed to import admin modules: {str(e)}")
except Exception as e:
    logger.error(f"Error setting up admin functionality: {str(e)}")

@app.get("/")
async def root():
    """Root endpoint."""
    return {"message": "Job Scraper API is running"}

@app.get("/health")
async def health():
    """Health check endpoint."""
    return {"status": "ok"}

# Add this to ensure FastAPI can find the app instance
if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8081) 