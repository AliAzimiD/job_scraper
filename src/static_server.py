"""Static file server for admin UI."""
import os
import logging
from pathlib import Path
from fastapi import FastAPI, HTTPException
from fastapi.staticfiles import StaticFiles
from fastapi.responses import FileResponse, JSONResponse

logger = logging.getLogger(__name__)

def setup_static_files(app: FastAPI, static_dir: str = "public") -> None:
    """Set up static file serving for the admin UI.
    
    Args:
        app: FastAPI application
        static_dir: Directory containing static files
    """
    try:
        # Convert to absolute path if not already
        static_path = Path(static_dir)
        if not static_path.is_absolute():
            # If we're in a package, get the parent directory
            module_dir = Path(__file__).parent
            project_dir = module_dir.parent
            static_path = project_dir / static_path
        
        # Create static directory if it doesn't exist
        os.makedirs(static_path, exist_ok=True)
        
        # Create admin directory if it doesn't exist
        admin_dir = static_path / "admin"
        os.makedirs(admin_dir, exist_ok=True)
        
        # Also create css and js directories
        os.makedirs(admin_dir / "css", exist_ok=True)
        os.makedirs(admin_dir / "js", exist_ok=True)
        
        logger.info(f"Static files directory: {static_path}")
        logger.info(f"Admin directory: {admin_dir}")
        
        # Mount static files
        try:
            app.mount("/static", StaticFiles(directory=str(static_path)), name="static")
            logger.info("Successfully mounted static files")
        except Exception as e:
            logger.error(f"Failed to mount static files: {str(e)}")
            # Continue without static file serving
    
        @app.get("/admin", include_in_schema=False)
        @app.get("/admin/", include_in_schema=False)
        async def serve_admin_index():
            """Serve the admin dashboard index page."""
            index_path = admin_dir / "index.html"
            if not index_path.exists():
                # If the file doesn't exist, return a helpful message
                return JSONResponse(
                    content={
                        "message": "Admin UI not found. Please run setup_admin.sh to create it.",
                        "status": "error"
                    },
                    status_code=404
                )
            return FileResponse(str(index_path))
        
        @app.get("/admin/{path:path}", include_in_schema=False)
        async def serve_admin_path(path: str):
            """Serve files from the admin directory."""
            full_path = admin_dir / path
            if not full_path.exists():
                if path.endswith((".html", ".js", ".css")):
                    return JSONResponse(
                        content={
                            "message": f"File {path} not found",
                            "status": "error"
                        },
                        status_code=404
                    )
                raise HTTPException(status_code=404, detail="File not found")
            return FileResponse(str(full_path))
            
    except Exception as e:
        logger.error(f"Error setting up static file serving: {str(e)}")
        # Continue without static file serving 