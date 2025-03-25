#!/bin/bash
set -e

VPS_IP="23.88.125.23"
VPS_USER="root"
VPS_PASS="jy6adu06wxefmvsi1kzo"

echo "=== Creating fixed docker-compose.monitoring.yml file ==="
cat > fixed_compose.yml << 'EOF'
version: '3.8'

services:
  prometheus:
    image: prom/prometheus:v2.44.0
    container_name: job-scraper-prometheus
    restart: unless-stopped
    volumes:
      - ./prometheus:/etc/prometheus
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=15d'
      - '--web.console.libraries=/etc/prometheus/console_libraries'
      - '--web.console.templates=/etc/prometheus/consoles'
      - '--web.enable-lifecycle'
    expose:
      - 9090
    ports:
      - "9090:9090"
    networks:
      - job-scraper-network

  grafana:
    image: grafana/grafana:10.0.3
    container_name: job-scraper-grafana
    restart: unless-stopped
    volumes:
      - grafana_data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
      - ./grafana/dashboards:/var/lib/grafana/dashboards
    environment:
      - GF_SECURITY_ADMIN_USER=admin
      - GF_SECURITY_ADMIN_PASSWORD=admin
      - GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH=/var/lib/grafana/dashboards/job_scraper_dashboard.json
      - GF_INSTALL_PLUGINS=grafana-piechart-panel,grafana-worldmap-panel
    expose:
      - 3000
    ports:
      - "3000:3000"
    networks:
      - job-scraper-network
    depends_on:
      - prometheus

  node-exporter:
    image: prom/node-exporter:v1.5.0
    container_name: job-scraper-node-exporter
    restart: unless-stopped
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)($$|/)'
    expose:
      - 9100
    networks:
      - job-scraper-network

  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:v0.12.0
    container_name: job-scraper-postgres-exporter
    restart: unless-stopped
    environment:
      - DATA_SOURCE_NAME=postgresql://jobuser:devpassword@job-scraper-db:5432/jobsdb?sslmode=disable
    expose:
      - 9187
    networks:
      - job-scraper-network
    # Removed dependency on db service

  redis-exporter:
    image: oliver006/redis_exporter:v1.45.0
    container_name: job-scraper-redis-exporter
    restart: unless-stopped
    environment:
      - REDIS_ADDR=redis://job-scraper-redis:6379
    expose:
      - 9121
    networks:
      - job-scraper-network
    # Removed dependency on redis service

  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.47.0
    container_name: job-scraper-cadvisor
    restart: unless-stopped
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    expose:
      - 8080
    networks:
      - job-scraper-network

volumes:
  prometheus_data:
  grafana_data:

networks:
  job-scraper-network:
    external: true
EOF

echo "=== Copying fixed file to server ==="
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no fixed_compose.yml $VPS_USER@$VPS_IP:/opt/job-scraper/docker-compose.monitoring.yml

echo "=== Starting services ==="
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP "cd /opt/job-scraper && docker-compose up -d && docker-compose -f docker-compose.monitoring.yml up -d"

echo "=== Checking service status ==="
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP "docker ps"

echo "=== Testing Web Application Health ==="
WEB_HEALTH=$(sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP "curl -s -o /dev/null -w '%{http_code}' http://localhost:5000/ || echo 'Web application not responding'")
echo "Web Application Status: $WEB_HEALTH"

echo "=== Testing Prometheus Health ==="
PROM_HEALTH=$(sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP "curl -s -o /dev/null -w '%{http_code}' http://localhost:9090/-/healthy || echo 'Prometheus not responding'")
echo "Prometheus Status: $PROM_HEALTH"

echo "=== Testing Grafana Health ==="
GRAFANA_HEALTH=$(sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no $VPS_USER@$VPS_IP "curl -s -o /dev/null -w '%{http_code}' http://localhost:3000/api/health || echo 'Grafana not responding'")
echo "Grafana Status: $GRAFANA_HEALTH"

echo "=== Application URLs ==="
echo "Web Application: http://$VPS_IP:5000"
echo "Prometheus: http://$VPS_IP:9090"
echo "Grafana: http://$VPS_IP:3000 (admin/admin)" 