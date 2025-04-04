"""Admin API routes for the job scraper."""
from fastapi import APIRouter, Request, Response, HTTPException
from fastapi.responses import JSONResponse
from typing import Dict, Any, List
import logging

# Import our admin API functions
from .admin_api import (
    get_stats, 
    get_logs,
    get_config,
    update_config,
    start_scrape,
    stop_scrape
)

# Create a router for admin endpoints
admin_router = APIRouter(prefix="/api", tags=["admin"])

@admin_router.get("/stats")
async def api_get_stats():
    """Get current scraping statistics."""
    try:
        return await get_stats()
    except Exception as e:
        logging.exception("Error getting stats")
        raise HTTPException(status_code=500, detail=str(e))

@admin_router.get("/logs")
async def api_get_logs(limit: int = 100):
    """Get recent scraping logs."""
    try:
        return await get_logs(limit)
    except Exception as e:
        logging.exception("Error getting logs")
        raise HTTPException(status_code=500, detail=str(e))

@admin_router.get("/config")
async def api_get_config():
    """Get current configuration."""
    try:
        return await get_config()
    except Exception as e:
        logging.exception("Error getting config")
        raise HTTPException(status_code=500, detail=str(e))

@admin_router.post("/config")
async def api_update_config(config: Dict[str, Any]):
    """Update configuration."""
    try:
        return await update_config(config)
    except Exception as e:
        logging.exception("Error updating config")
        raise HTTPException(status_code=500, detail=str(e))

@admin_router.post("/scrape/start")
async def api_start_scrape():
    """Start a manual scraping job."""
    try:
        return await start_scrape()
    except Exception as e:
        logging.exception("Error starting scrape")
        raise HTTPException(status_code=500, detail=str(e))

@admin_router.post("/scrape/stop")
async def api_stop_scrape():
    """Stop current scraping job."""
    try:
        return await stop_scrape()
    except Exception as e:
        logging.exception("Error stopping scrape")
        raise HTTPException(status_code=500, detail=str(e))

# Helper function to add these routes to an existing FastAPI app
def add_admin_routes(app):
    """Add admin routes to the given FastAPI app."""
    app.include_router(admin_router)
    return app 