#!/usr/bin/env python3
"""
Comprehensive test script to verify the functionality of the Job Scraper application.
"""

import requests
import json
import os
import time
from pprint import pprint
from datetime import datetime

BASE_URL = "http://localhost:5001"

class JobScraperTester:
    """Class to test the Job Scraper application."""
    
    def __init__(self, base_url=BASE_URL):
        """Initialize the tester with the base URL."""
        self.base_url = base_url
        self.test_results = {}
        self.log_file = f"test_results_{datetime.now().strftime('%Y%m%d_%H%M%S')}.log"
        
        # Create a log file
        with open(self.log_file, 'w') as f:
            f.write(f"Job Scraper Test Results - {datetime.now()}\n")
            f.write("=" * 50 + "\n\n")
    
    def log(self, message):
        """Log a message to the console and the log file."""
        print(message)
        with open(self.log_file, 'a') as f:
            f.write(message + "\n")
    
    def test_health_endpoint(self):
        """Test the health endpoint."""
        self.log("\n--- Testing Health Endpoint ---")
        
        try:
            response = requests.get(f"{self.base_url}/health")
            self.log(f"Status Code: {response.status_code}")
            data = response.json()
            self.log(f"Response: {data}")
            
            result = response.status_code == 200 and data.get("status") == "ok"
            self.test_results["health_endpoint"] = result
            return result
        except Exception as e:
            self.log(f"Error: {str(e)}")
            self.test_results["health_endpoint"] = False
            return False
    
    def test_metrics_endpoint(self):
        """Test the metrics endpoint."""
        self.log("\n--- Testing Metrics Endpoint ---")
        
        try:
            response = requests.get(f"{self.base_url}/metrics")
            self.log(f"Status Code: {response.status_code}")
            
            result = response.status_code == 200
            self.test_results["metrics_endpoint"] = result
            return result
        except Exception as e:
            self.log(f"Error: {str(e)}")
            self.test_results["metrics_endpoint"] = False
            return False
    
    def test_static_files(self):
        """Test access to static files."""
        self.log("\n--- Testing Static Files ---")
        
        files_to_test = [
            "/static/js/script.js",
            "/static/css/style.css"
        ]
        
        all_passed = True
        for file_path in files_to_test:
            try:
                response = requests.head(f"{self.base_url}{file_path}")
                status = "PASSED" if response.status_code == 200 else "FAILED"
                self.log(f"{file_path}: {status} (Status Code: {response.status_code})")
                
                if response.status_code != 200:
                    all_passed = False
            except Exception as e:
                self.log(f"{file_path}: FAILED (Error: {str(e)})")
                all_passed = False
        
        self.test_results["static_files"] = all_passed
        return all_passed
    
    def test_scraper_status(self):
        """Test the scraper status endpoint."""
        self.log("\n--- Testing Scraper Status Endpoint ---")
        
        try:
            response = requests.get(f"{self.base_url}/api/scraper-status")
            self.log(f"Status Code: {response.status_code}")
            
            if response.status_code == 200:
                data = response.json()
                self.log("Response:")
                for key, value in data.items():
                    self.log(f"  {key}: {value}")
                
                result = "status" in data
                self.test_results["scraper_status"] = result
                return result
            else:
                self.log(f"Error: Unexpected status code {response.status_code}")
                self.test_results["scraper_status"] = False
                return False
        except Exception as e:
            self.log(f"Error: {str(e)}")
            self.test_results["scraper_status"] = False
            return False
    
    def test_start_scraper(self):
        """Test starting the scraper."""
        self.log("\n--- Testing Start Scraper Endpoint ---")
        
        try:
            response = requests.post(
                f"{self.base_url}/api/start-scrape",
                json={"max_pages": 2}
            )
            self.log(f"Status Code: {response.status_code}")
            
            if response.status_code == 200:
                data = response.json()
                self.log("Response:")
                self.log(f"  success: {data.get('success')}")
                self.log(f"  message: {data.get('message')}")
                self.log(f"  status: running={data.get('status', {}).get('running', False)}")
                
                result = data.get("success", False) and data.get("status", {}).get("running", False)
                self.test_results["start_scraper"] = result
                
                # Wait for scraper to make some progress
                self.log("\nWaiting for scraper to make progress...")
                time.sleep(5)
                progress_response = requests.get(f"{self.base_url}/api/scraper-status")
                progress_data = progress_response.json()
                self.log(f"Progress after 5 seconds: {progress_data.get('progress')}%")
                self.log(f"Jobs found: {progress_data.get('jobs_found')}")
                
                return result
            else:
                self.log(f"Error: Unexpected status code {response.status_code}")
                self.test_results["start_scraper"] = False
                return False
        except Exception as e:
            self.log(f"Error: {str(e)}")
            self.test_results["start_scraper"] = False
            return False
    
    def test_stop_scraper(self):
        """Test stopping the scraper."""
        self.log("\n--- Testing Stop Scraper Endpoint ---")
        
        # First check if the scraper is running
        status_response = requests.get(f"{self.base_url}/api/scraper-status")
        status_data = status_response.json()
        
        if not status_data.get("running", False):
            self.log("Scraper is not running, starting it first...")
            requests.post(
                f"{self.base_url}/api/start-scrape",
                json={"max_pages": 5}
            )
            time.sleep(2)  # Wait for scraper to start
        
        try:
            response = requests.post(
                f"{self.base_url}/api/stop-scrape",
                json={}
            )
            self.log(f"Status Code: {response.status_code}")
            
            data = response.json()
            self.log("Response:")
            self.log(f"  success: {data.get('success')}")
            self.log(f"  message: {data.get('message')}")
            self.log(f"  status: running={data.get('status', {}).get('running', False)}")
            
            result = not data.get("status", {}).get("running", True)
            self.test_results["stop_scraper"] = result
            return result
        except Exception as e:
            self.log(f"Error: {str(e)}")
            self.test_results["stop_scraper"] = False
            return False
    
    def test_export_json(self):
        """Test exporting data in JSON format."""
        self.log("\n--- Testing JSON Export ---")
        
        try:
            response = requests.post(
                f"{self.base_url}/api/export-db",
                json={"format": "json"}
            )
            self.log(f"Status Code: {response.status_code}")
            
            if response.status_code == 200:
                data = response.json()
                self.log(f"Response: {data}")
                
                result = data.get("success", False)
                self.test_results["export_json"] = result
                return result
            else:
                self.log(f"Error: Unexpected status code {response.status_code}")
                self.test_results["export_json"] = False
                return False
        except Exception as e:
            self.log(f"Error: {str(e)}")
            self.test_results["export_json"] = False
            return False
    
    def test_error_handling(self):
        """Test error handling for 404 errors."""
        self.log("\n--- Testing Error Handling (404) ---")
        
        try:
            response = requests.get(f"{self.base_url}/non-existent-page")
            self.log(f"Status Code: {response.status_code}")
            
            result = response.status_code == 404
            self.test_results["error_handling_404"] = result
            return result
        except Exception as e:
            self.log(f"Error: {str(e)}")
            self.test_results["error_handling_404"] = False
            return False
    
    def run_all_tests(self):
        """Run all tests and display a summary."""
        self.log("\n=== Running All Tests ===\n")
        
        tests = [
            ("Health Endpoint", self.test_health_endpoint),
            ("Metrics Endpoint", self.test_metrics_endpoint),
            ("Static Files", self.test_static_files),
            ("Scraper Status", self.test_scraper_status),
            ("Start Scraper", self.test_start_scraper),
            ("Wait for scraper to finish...", lambda: time.sleep(10)),
            ("Stop Scraper", self.test_stop_scraper),
            ("Export JSON", self.test_export_json),
            ("Error Handling (404)", self.test_error_handling)
        ]
        
        for test_name, test_func in tests:
            if callable(test_func):
                self.log(f"\nRunning Test: {test_name}")
                test_func()
            else:
                self.log(test_name)
        
        self.display_summary()
    
    def display_summary(self):
        """Display a summary of all test results."""
        self.log("\n\n=== Test Summary ===\n")
        
        passed = 0
        failed = 0
        
        for test, result in self.test_results.items():
            status = "PASSED" if result else "FAILED"
            if result:
                passed += 1
            else:
                failed += 1
            self.log(f"{test}: {status}")
        
        self.log(f"\nTotal Tests: {len(self.test_results)}")
        self.log(f"Passed: {passed}")
        self.log(f"Failed: {failed}")
        
        if failed == 0:
            self.log("\nAll tests PASSED! The application is functioning correctly.")
        else:
            self.log(f"\n{failed} test(s) FAILED. Please check the logs for details.")
        
        self.log(f"\nTest results saved to: {self.log_file}")

def main():
    """Run all tests on the Job Scraper application."""
    tester = JobScraperTester()
    tester.run_all_tests()

if __name__ == "__main__":
    main() 