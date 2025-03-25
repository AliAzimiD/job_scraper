#!/usr/bin/env python3
"""
Test script to verify the export functionality of the Job Scraper application.
"""

import requests
import json
import os
import time
from pprint import pprint

BASE_URL = "http://localhost:5001"

def test_export_json():
    """Test exporting data in JSON format."""
    print("\n--- Testing JSON Export ---")
    
    # Make export request
    response = requests.post(
        f"{BASE_URL}/api/export-db",
        json={"format": "json"}
    )
    
    # Check response
    print(f"Status Code: {response.status_code}")
    data = response.json()
    pprint(data)
    
    # Check if file was created
    if data.get("success") and data.get("file"):
        filename = data.get("file")
        file_path = os.path.join("uploads", filename)
        
        # Wait a bit for file to be fully written
        time.sleep(1)
        
        if os.path.exists(file_path):
            file_size = os.path.getsize(file_path)
            print(f"File created: {filename} ({file_size} bytes)")
            
            # Read and display file contents
            with open(file_path, 'r') as f:
                file_data = json.load(f)
                print("\nFile Contents:")
                pprint(file_data)
        else:
            print(f"Error: File {filename} was not created")
    
    return data.get("success", False)

def test_export_csv():
    """Test exporting data in CSV format."""
    print("\n--- Testing CSV Export ---")
    
    # Make export request
    response = requests.post(
        f"{BASE_URL}/api/export-db",
        json={"format": "csv"}
    )
    
    # Check response
    print(f"Status Code: {response.status_code}")
    data = response.json()
    pprint(data)
    
    # Check if file was created
    if data.get("success") and data.get("file"):
        filename = data.get("file")
        file_path = os.path.join("uploads", filename)
        
        # Wait a bit for file to be fully written
        time.sleep(1)
        
        if os.path.exists(file_path):
            file_size = os.path.getsize(file_path)
            print(f"File created: {filename} ({file_size} bytes)")
            
            # Read and display file contents
            with open(file_path, 'r') as f:
                file_data = f.read()
                print("\nFile Contents:")
                print(file_data)
        else:
            print(f"Error: File {filename} was not created")
    
    return data.get("success", False)

def main():
    """Run all tests."""
    test_results = {
        "json_export": test_export_json(),
        "csv_export": test_export_csv()
    }
    
    print("\n--- Test Summary ---")
    for test, result in test_results.items():
        status = "PASSED" if result else "FAILED"
        print(f"{test}: {status}")
    
    # Check overall result
    if all(test_results.values()):
        print("\nAll tests PASSED!")
        return 0
    else:
        print("\nSome tests FAILED!")
        return 1

if __name__ == "__main__":
    exit(main()) 