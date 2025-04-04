#!/usr/bin/env python3
"""
Test script to verify the Job Scraper Admin Dashboard setup.
This script checks for the required files and dependencies.
"""

import os
import sys
import importlib
import json
from pathlib import Path

# Color formatting for terminal output
GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
RESET = "\033[0m"
BOLD = "\033[1m"

def success(message):
    """Print a success message."""
    print(f"{GREEN}✓ {message}{RESET}")

def warning(message):
    """Print a warning message."""
    print(f"{YELLOW}! {message}{RESET}")

def error(message):
    """Print an error message."""
    print(f"{RED}✗ {message}{RESET}")

def header(message):
    """Print a header message."""
    print(f"\n{BOLD}{message}{RESET}")

def check_directory(path, create=False):
    """Check if a directory exists, optionally create it."""
    path_obj = Path(path)
    if path_obj.exists() and path_obj.is_dir():
        success(f"Directory exists: {path}")
        return True
    elif create:
        try:
            path_obj.mkdir(parents=True, exist_ok=True)
            success(f"Created directory: {path}")
            return True
        except Exception as e:
            error(f"Failed to create directory {path}: {e}")
            return False
    else:
        error(f"Directory not found: {path}")
        return False

def check_file(path):
    """Check if a file exists."""
    if os.path.isfile(path):
        success(f"File exists: {path}")
        return True
    else:
        error(f"File not found: {path}")
        return False

def check_module(module_name):
    """Check if a Python module can be imported."""
    try:
        importlib.import_module(module_name)
        success(f"Module {module_name} is available")
        return True
    except ImportError:
        error(f"Module {module_name} is not installed")
        return False

def main():
    """Main test function."""
    # Get the script's directory
    script_dir = os.path.dirname(os.path.abspath(__file__))
    project_root = os.path.dirname(script_dir)
    
    header("Job Scraper Admin Dashboard Test")
    print(f"Project root: {project_root}\n")
    
    # Check required directories
    header("Checking directories")
    dirs_ok = True
    dirs_ok &= check_directory(os.path.join(project_root, "public"))
    dirs_ok &= check_directory(os.path.join(project_root, "public", "admin"))
    dirs_ok &= check_directory(os.path.join(project_root, "public", "admin", "css"))
    dirs_ok &= check_directory(os.path.join(project_root, "public", "admin", "js"))
    dirs_ok &= check_directory(os.path.join(project_root, "logs"))
    
    # Check required files
    header("Checking files")
    files_ok = True
    files_ok &= check_file(os.path.join(project_root, "src", "admin_api.py"))
    files_ok &= check_file(os.path.join(project_root, "src", "admin_routes.py"))
    files_ok &= check_file(os.path.join(project_root, "src", "static_server.py"))
    files_ok &= check_file(os.path.join(project_root, "public", "admin", "index.html"))
    files_ok &= check_file(os.path.join(project_root, "public", "admin", "css", "admin.css"))
    files_ok &= check_file(os.path.join(project_root, "public", "admin", "js", "admin.js"))
    
    # Check dependencies
    header("Checking dependencies")
    deps_ok = True
    deps_ok &= check_module("fastapi")
    deps_ok &= check_module("uvicorn")
    
    # Check if main.py imports admin routes
    header("Checking integration")
    main_py = os.path.join(project_root, "src", "main.py")
    if check_file(main_py):
        with open(main_py, 'r') as f:
            content = f.read()
            if "from .admin_routes import add_admin_routes" in content:
                success("main.py imports admin_routes")
            else:
                warning("main.py does not import admin_routes")
                print("Add the following to main.py:")
                print("  from .admin_routes import add_admin_routes")
                print("  add_admin_routes(app)")
            
            if "from .static_server import setup_static_files" in content:
                success("main.py imports static_server")
            else:
                warning("main.py does not import static_server")
                print("Add the following to main.py:")
                print("  from .static_server import setup_static_files")
                print("  setup_static_files(app)")
    
    # Summary
    header("Test Summary")
    if dirs_ok and files_ok and deps_ok:
        success("All tests passed! The admin dashboard is properly set up.")
        print("\nTo start the server, run:")
        print(f"  cd {project_root} && python3 -m src.main")
        print("\nThen access the admin dashboard at:")
        print("  http://localhost:8000/admin")
    else:
        error("Some tests failed. Please fix the issues above.")
        print("\nRun the setup script to fix issues:")
        print(f"  {os.path.join(script_dir, 'setup_admin.sh')}")

if __name__ == "__main__":
    main() 