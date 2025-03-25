#!/bin/bash

export VPS_PASS="jy6adu06wxefmvsi1kzo"

echo "Installing dependencies on VPS..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "pip install aiohttp asyncio"

echo "Running the simplified scraper after installing dependencies..."
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "cd /opt/job-scraper && python3 simple_scraper.py"

echo "Dependencies installed and scraper test completed." 