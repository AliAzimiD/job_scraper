#!/usr/bin/env python3
"""
Test script for the Job Scraper Admin API
"""

import os
import sys
import requests
import json
import time
from colorama import init, Fore, Style

# Add the parent directory to the path so we can import the modules
parent_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, parent_dir)

# Initialize colorama for colored terminal output
init()

# Base URL for API requests
BASE_URL = "http://localhost:8081"

def print_header(message):
    """Print a header with the given message"""
    print(f"\n{Fore.CYAN}{Style.BRIGHT}" + "=" * 60)
    print(f" {message}")
    print("=" * 60 + f"{Style.RESET_ALL}\n")

def print_success(message):
    """Print a success message"""
    print(f"{Fore.GREEN}✓ {message}{Style.RESET_ALL}")

def print_error(message):
    """Print an error message"""
    print(f"{Fore.RED}✗ {message}{Style.RESET_ALL}")

def test_get_stats():
    """Test the GET /api/stats endpoint"""
    print_header("Testing GET /api/stats")
    try:
        response = requests.get(f"{BASE_URL}/api/stats")
        if response.status_code == 200:
            data = response.json()
            print_success(f"Status code: {response.status_code}")
            print(json.dumps(data, indent=2))
            return True
        else:
            print_error(f"Status code: {response.status_code}")
            print(response.text)
            return False
    except Exception as e:
        print_error(f"Error: {str(e)}")
        return False

def test_get_logs():
    """Test the GET /api/logs endpoint"""
    print_header("Testing GET /api/logs")
    try:
        response = requests.get(f"{BASE_URL}/api/logs?limit=5")
        if response.status_code == 200:
            data = response.json()
            print_success(f"Status code: {response.status_code}")
            print(json.dumps(data, indent=2))
            return True
        else:
            print_error(f"Status code: {response.status_code}")
            print(response.text)
            return False
    except Exception as e:
        print_error(f"Error: {str(e)}")
        return False

def test_get_config():
    """Test the GET /api/config endpoint"""
    print_header("Testing GET /api/config")
    try:
        response = requests.get(f"{BASE_URL}/api/config")
        if response.status_code == 200:
            data = response.json()
            print_success(f"Status code: {response.status_code}")
            print(json.dumps(data, indent=2))
            return True
        else:
            print_error(f"Status code: {response.status_code}")
            print(response.text)
            return False
    except Exception as e:
        print_error(f"Error: {str(e)}")
        return False

def test_start_scrape():
    """Test the POST /api/scrape/start endpoint"""
    print_header("Testing POST /api/scrape/start")
    try:
        response = requests.post(f"{BASE_URL}/api/scrape/start")
        if response.status_code == 200:
            data = response.json()
            print_success(f"Status code: {response.status_code}")
            print(json.dumps(data, indent=2))
            return True
        else:
            print_error(f"Status code: {response.status_code}")
            print(response.text)
            return False
    except Exception as e:
        print_error(f"Error: {str(e)}")
        return False

def test_stop_scrape():
    """Test the POST /api/scrape/stop endpoint"""
    print_header("Testing POST /api/scrape/stop")
    try:
        response = requests.post(f"{BASE_URL}/api/scrape/stop")
        if response.status_code == 200:
            data = response.json()
            print_success(f"Status code: {response.status_code}")
            print(json.dumps(data, indent=2))
            return True
        else:
            print_error(f"Status code: {response.status_code}")
            print(response.text)
            return False
    except Exception as e:
        print_error(f"Error: {str(e)}")
        return False

def test_update_config():
    """Test the POST /api/config endpoint"""
    print_header("Testing POST /api/config")
    try:
        # First get the current config
        get_response = requests.get(f"{BASE_URL}/api/config")
        if get_response.status_code != 200:
            print_error(f"Failed to get current config: {get_response.status_code}")
            return False
            
        current_config = get_response.json()
        
        # Make a copy to update
        updated_config = current_config.copy()
        
        # Update a test value if it exists, otherwise add a test value
        if "test_key" in updated_config:
            updated_config["test_key"] = f"test_value_{int(time.time())}"
        else:
            updated_config["test_key"] = f"test_value_{int(time.time())}"
        
        # Send the updated config
        response = requests.post(
            f"{BASE_URL}/api/config",
            json=updated_config
        )
        
        if response.status_code == 200:
            data = response.json()
            print_success(f"Status code: {response.status_code}")
            print(json.dumps(data, indent=2))
            return True
        else:
            print_error(f"Status code: {response.status_code}")
            print(response.text)
            return False
    except Exception as e:
        print_error(f"Error: {str(e)}")
        return False

def test_admin_dashboard():
    """Test the /admin endpoint"""
    print_header("Testing /admin endpoint")
    try:
        response = requests.get(f"{BASE_URL}/admin")
        if response.status_code == 200:
            print_success(f"Status code: {response.status_code}")
            print(f"Dashboard HTML length: {len(response.text)} characters")
            return True
        else:
            print_error(f"Status code: {response.status_code}")
            print(response.text)
            return False
    except Exception as e:
        print_error(f"Error: {str(e)}")
        return False

def run_all_tests():
    """Run all tests and report results"""
    print_header("Running all tests for Job Scraper Admin API")
    
    results = {
        "Admin Dashboard": test_admin_dashboard(),
        "GET /api/stats": test_get_stats(),
        "GET /api/logs": test_get_logs(),
        "GET /api/config": test_get_config(),
        "POST /api/config": test_update_config(),
        "POST /api/scrape/start": test_start_scrape(),
        "POST /api/scrape/stop": test_stop_scrape(),
    }
    
    print_header("Test Results Summary")
    passed = 0
    failed = 0
    
    for test_name, result in results.items():
        if result:
            print_success(f"{test_name}: PASSED")
            passed += 1
        else:
            print_error(f"{test_name}: FAILED")
            failed += 1
    
    print(f"\n{Fore.CYAN}{Style.BRIGHT}Summary: {passed} passed, {failed} failed{Style.RESET_ALL}")
    
    if failed == 0:
        print(f"\n{Fore.GREEN}{Style.BRIGHT}All tests passed! The Admin API is working correctly.{Style.RESET_ALL}")
    else:
        print(f"\n{Fore.YELLOW}{Style.BRIGHT}Some tests failed. Please check the server logs for more information.{Style.RESET_ALL}")

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--help":
        print("Usage: python test_admin_api.py [test_name]")
        print("Available tests:")
        print("  all (default) - Run all tests")
        print("  dashboard - Test admin dashboard")
        print("  stats - Test GET /api/stats")
        print("  logs - Test GET /api/logs")
        print("  config - Test GET /api/config")
        print("  update_config - Test POST /api/config")
        print("  start - Test POST /api/scrape/start")
        print("  stop - Test POST /api/scrape/stop")
        sys.exit(0)
    
    test_name = sys.argv[1] if len(sys.argv) > 1 else "all"
    
    if test_name == "all":
        run_all_tests()
    elif test_name == "dashboard":
        test_admin_dashboard()
    elif test_name == "stats":
        test_get_stats()
    elif test_name == "logs":
        test_get_logs()
    elif test_name == "config":
        test_get_config()
    elif test_name == "update_config":
        test_update_config()
    elif test_name == "start":
        test_start_scrape()
    elif test_name == "stop":
        test_stop_scrape()
    else:
        print(f"Unknown test: {test_name}")
        print("Use --help for available tests") 