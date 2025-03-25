#!/usr/bin/env python3
"""
Test script for the Job Scraper monitoring integration.
This script checks if the monitoring components are correctly set up and accessible.
"""

import os
import sys
import time
import json
import argparse
import random
import logging
from datetime import datetime
import urllib.request
import urllib.error

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    datefmt='%Y-%m-%d %H:%M:%S'
)
logger = logging.getLogger('monitoring-test')

def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(description='Test Job Scraper monitoring setup')
    parser.add_argument('--prometheus-url', default='http://localhost:9090',
                        help='Prometheus URL (default: http://localhost:9090)')
    parser.add_argument('--grafana-url', default='http://localhost:3000',
                        help='Grafana URL (default: http://localhost:3000)')
    parser.add_argument('--web-app-url', default='http://localhost:5000',
                        help='Job Scraper web app URL (default: http://localhost:5000)')
    parser.add_argument('--debug', action='store_true',
                        help='Enable debug logging')
    parser.add_argument('--csv', action='store_true',
                        help='Output results in CSV format')
    return parser.parse_args()

def check_service(url, service_name):
    """Check if a service is accessible."""
    try:
        logger.debug(f"Checking {service_name} at {url}")
        response = urllib.request.urlopen(url, timeout=5)
        return response.status == 200
    except (urllib.error.URLError, urllib.error.HTTPError, ConnectionError) as e:
        logger.debug(f"Error checking {service_name}: {e}")
        return False
    except Exception as e:
        logger.debug(f"Unexpected error checking {service_name}: {e}")
        return False

def check_metrics_endpoint(web_app_url):
    """Check if the metrics endpoint is available on the web app."""
    try:
        logger.debug(f"Checking metrics endpoint at {web_app_url}/metrics")
        response = urllib.request.urlopen(f"{web_app_url}/metrics", timeout=5)
        return response.status == 200
    except (urllib.error.URLError, urllib.error.HTTPError, ConnectionError) as e:
        logger.debug(f"Error checking metrics endpoint: {e}")
        return False
    except Exception as e:
        logger.debug(f"Unexpected error checking metrics endpoint: {e}")
        return False

def check_prometheus_targets(prometheus_url):
    """Check Prometheus targets and their status."""
    try:
        logger.debug(f"Checking Prometheus targets at {prometheus_url}/api/v1/targets")
        response = urllib.request.urlopen(f"{prometheus_url}/api/v1/targets", timeout=5)
        data = json.loads(response.read().decode('utf-8'))
        
        targets = []
        up_count = 0
        total_count = 0
        
        if data['status'] == 'success' and 'data' in data:
            for target_group in data['data']['activeTargets']:
                target_name = target_group.get('labels', {}).get('job', 'unknown')
                target_status = target_group.get('health', 'unknown')
                total_count += 1
                if target_status == 'up':
                    up_count += 1
                targets.append({
                    'name': target_name,
                    'status': target_status,
                    'last_scrape': target_group.get('lastScrape', 'unknown')
                })
        
        return {
            'success': True,
            'targets': targets,
            'up_count': up_count,
            'total_count': total_count
        }
    except (urllib.error.URLError, urllib.error.HTTPError, ConnectionError) as e:
        logger.debug(f"Error checking Prometheus targets: {e}")
        return {'success': False, 'error': str(e)}
    except Exception as e:
        logger.debug(f"Unexpected error checking Prometheus targets: {e}")
        return {'success': False, 'error': str(e)}

def check_grafana_datasources(grafana_url):
    """Check Grafana datasources."""
    try:
        # This is a simple check, in production you'd need proper authentication
        logger.debug(f"Checking Grafana datasources at {grafana_url}/api/datasources")
        
        # We can't easily check this without authentication, so we'll just check if login page loads
        response = urllib.request.urlopen(f"{grafana_url}/login", timeout=5)
        return response.status == 200
    except (urllib.error.URLError, urllib.error.HTTPError, ConnectionError) as e:
        logger.debug(f"Error checking Grafana datasources: {e}")
        return False
    except Exception as e:
        logger.debug(f"Unexpected error checking Grafana datasources: {e}")
        return False

def validate_prometheus_queries(prometheus_url, queries):
    """Run validation queries against Prometheus."""
    results = []
    
    for query_name, query in queries.items():
        try:
            logger.debug(f"Running Prometheus query '{query_name}': {query}")
            encoded_query = urllib.parse.quote(query)
            url = f"{prometheus_url}/api/v1/query?query={encoded_query}"
            response = urllib.request.urlopen(url, timeout=5)
            data = json.loads(response.read().decode('utf-8'))
            
            if data['status'] == 'success':
                has_data = len(data.get('data', {}).get('result', [])) > 0
                results.append({
                    'name': query_name,
                    'success': True,
                    'has_data': has_data
                })
            else:
                results.append({
                    'name': query_name,
                    'success': False,
                    'error': 'Query returned unsuccessful status'
                })
        except Exception as e:
            logger.debug(f"Error running query '{query_name}': {e}")
            results.append({
                'name': query_name,
                'success': False,
                'error': str(e)
            })
    
    return results

def run_tests(args):
    """Run all monitoring tests."""
    test_results = {}
    
    # Check if services are accessible
    test_results['prometheus_accessible'] = check_service(args.prometheus_url, 'Prometheus')
    test_results['grafana_accessible'] = check_service(args.grafana_url, 'Grafana')
    test_results['web_app_accessible'] = check_service(args.web_app_url, 'Web App')
    test_results['metrics_endpoint'] = check_metrics_endpoint(args.web_app_url) if test_results['web_app_accessible'] else False
    
    # Check Prometheus targets
    if test_results['prometheus_accessible']:
        test_results['prometheus_targets'] = check_prometheus_targets(args.prometheus_url)
    else:
        test_results['prometheus_targets'] = {'success': False, 'error': 'Prometheus not accessible'}
    
    # Check Grafana datasources
    if test_results['grafana_accessible']:
        test_results['grafana_datasources'] = check_grafana_datasources(args.grafana_url)
    else:
        test_results['grafana_datasources'] = False
    
    # Run validation queries against Prometheus
    if test_results['prometheus_accessible']:
        validation_queries = {
            'up': 'up',
            'job_count': 'job_scraper_total_jobs',
            'errors': 'job_scraper_errors_total',
            'api_requests': 'job_scraper_api_requests_total'
        }
        test_results['prometheus_queries'] = validate_prometheus_queries(args.prometheus_url, validation_queries)
    else:
        test_results['prometheus_queries'] = []
    
    return test_results

def print_test_results(results, csv_format=False):
    """Print the test results."""
    if csv_format:
        print("test,result")
        print(f"prometheus_accessible,{results['prometheus_accessible']}")
        print(f"grafana_accessible,{results['grafana_accessible']}")
        print(f"web_app_accessible,{results['web_app_accessible']}")
        print(f"metrics_endpoint,{results['metrics_endpoint']}")
        
        if results['prometheus_accessible'] and results['prometheus_targets']['success']:
            print(f"prometheus_targets_up,{results['prometheus_targets']['up_count']}")
            print(f"prometheus_targets_total,{results['prometheus_targets']['total_count']}")
        
        print(f"grafana_datasources,{results['grafana_datasources']}")
        
        for query in results['prometheus_queries']:
            print(f"prometheus_query_{query['name']},{query['success']}")
    else:
        print("\n=== Job Scraper Monitoring Test Results ===")
        print(f"Test run time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print("\n1. Service Accessibility:")
        print(f"   - Prometheus: {'✅ Accessible' if results['prometheus_accessible'] else '❌ Not accessible'}")
        print(f"   - Grafana: {'✅ Accessible' if results['grafana_accessible'] else '❌ Not accessible'}")
        print(f"   - Web App: {'✅ Accessible' if results['web_app_accessible'] else '❌ Not accessible'}")
        print(f"   - Metrics Endpoint: {'✅ Available' if results['metrics_endpoint'] else '❌ Not available'}")
        
        print("\n2. Prometheus Targets:")
        if results['prometheus_accessible'] and results['prometheus_targets']['success']:
            targets = results['prometheus_targets']['targets']
            up_count = results['prometheus_targets']['up_count']
            total_count = results['prometheus_targets']['total_count']
            print(f"   - Status: {up_count}/{total_count} targets up")
            
            for target in targets:
                status_icon = '✅' if target['status'] == 'up' else '❌'
                print(f"   - {status_icon} {target['name']}: {target['status']}")
        else:
            print("   - Unable to retrieve target information")
        
        print("\n3. Grafana Setup:")
        print(f"   - Datasources: {'✅ Available' if results['grafana_datasources'] else '❌ Not available or requires authentication'}")
        
        print("\n4. Prometheus Queries:")
        if results['prometheus_queries']:
            for query in results['prometheus_queries']:
                if query['success']:
                    data_status = '✅ Has data' if query.get('has_data', False) else '⚠️ No data'
                    print(f"   - ✅ {query['name']}: Success - {data_status}")
                else:
                    print(f"   - ❌ {query['name']}: Failed - {query.get('error', 'Unknown error')}")
        else:
            print("   - No query validation performed")
        
        print("\n=== Overall Assessment ===")
        if (results['prometheus_accessible'] and 
            results['grafana_accessible'] and 
            results['web_app_accessible'] and 
            results['metrics_endpoint']):
            print("✅ Basic monitoring setup is COMPLETE")
            
            if (results['prometheus_targets']['success'] and 
                results['prometheus_targets']['up_count'] > 0):
                print("✅ Prometheus is scraping targets successfully")
            else:
                print("⚠️ Prometheus is not scraping all targets")
            
            if results['grafana_datasources']:
                print("✅ Grafana appears to be set up correctly")
            else:
                print("⚠️ Grafana may need configuration or authentication")
            
            query_success = all(q['success'] for q in results['prometheus_queries'])
            if query_success:
                print("✅ Prometheus queries are working")
            else:
                print("⚠️ Some Prometheus queries failed")
        else:
            print("❌ Basic monitoring setup is INCOMPLETE")
        
        print("\nFor detailed instructions on completing the setup, refer to MONITORING.md")

def main():
    """Main function."""
    args = parse_args()
    
    if args.debug:
        logger.setLevel(logging.DEBUG)
    
    try:
        test_results = run_tests(args)
        print_test_results(test_results, args.csv)
        
        # Return success if basic setup is complete
        if (test_results['prometheus_accessible'] and 
            test_results['grafana_accessible'] and 
            test_results['web_app_accessible'] and 
            test_results['metrics_endpoint']):
            return 0
        else:
            return 1
    except Exception as e:
        logger.error(f"Unexpected error during testing: {e}")
        return 2

if __name__ == "__main__":
    sys.exit(main()) 