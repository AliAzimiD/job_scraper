#!/bin/bash
set -e

export VPS_PASS="jy6adu06wxefmvsi1kzo"

echo "=== Fixing Docker Compose Configuration ==="
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no update_docker_compose_monitoring.yml root@23.88.125.23:/opt/job-scraper/docker-compose.monitoring.yml

echo "=== Starting All Services ==="
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "cd /opt/job-scraper && docker-compose up -d && docker-compose -f docker-compose.monitoring.yml up -d"

echo "=== Checking Service Status ==="
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "docker ps"

echo "=== Testing Web Application Health ==="
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "curl -s -o /dev/null -w '%{http_code}' http://localhost:5000/ || echo 'Web application not responding'"

echo "=== Testing Prometheus Health ==="
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "curl -s -o /dev/null -w '%{http_code}' http://localhost:9090/-/healthy || echo 'Prometheus not responding'"

echo "=== Testing Grafana Health ==="
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/api/health || echo 'Grafana not responding'"

echo "=== Application URLs ==="
echo "Web Application: http://23.88.125.23:5000"
echo "Prometheus: http://23.88.125.23:9090"
echo "Grafana: http://23.88.125.23:3000 (admin/admin)" 