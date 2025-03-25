# Job Scraper Monitoring Setup

This document outlines the monitoring setup for the Job Scraper application using Prometheus and Grafana.

## Overview

The monitoring stack consists of:

1. **Prometheus** - For collecting and storing metrics
2. **Grafana** - For visualizing metrics with dashboards
3. **Node Exporter** - For system metrics (CPU, memory, disk, network)
4. **PostgreSQL Exporter** - For database metrics
5. **Redis Exporter** - For Redis metrics
6. **cAdvisor** - For container metrics

The Job Scraper application has been instrumented with Prometheus metrics to track:
- Job scraping statistics (total jobs, new jobs, errors, retries)
- API request metrics (count, duration, status)
- Resource usage (CPU, memory)
- Database operation performance

## Prerequisites

- Docker and Docker Compose installed
- Job Scraper application running

## Getting Started

### 1. Start the Monitoring Stack

```bash
# Start the monitoring services
docker-compose -f docker-compose.monitoring.yml up -d
```

### 2. Access Monitoring Dashboards

- **Prometheus**: http://localhost:9090
- **Grafana**: http://localhost:3000 (default credentials: admin/admin)

## Available Metrics

### Job Scraper Application Metrics

| Metric Name | Type | Description |
|-------------|------|-------------|
| `job_scraper_total_jobs` | Gauge | Total number of jobs in the database |
| `job_scraper_new_jobs_total` | Counter | Number of new jobs scraped |
| `job_scraper_errors_total` | Counter | Number of scraper errors by type |
| `job_scraper_retries_total` | Counter | Number of scraper retries |
| `job_scraper_api_requests_total` | Counter | Number of API requests by method, endpoint, status |
| `job_scraper_api_request_duration_seconds` | Histogram | API request duration in seconds |
| `job_scraper_scrape_duration_seconds` | Histogram | Time spent scraping jobs by source |
| `job_scraper_db_operation_duration_seconds` | Histogram | Time spent on database operations |
| `job_scraper_cpu_usage` | Gauge | CPU usage percentage |
| `job_scraper_memory_usage_bytes` | Gauge | Memory usage in bytes |
| `job_scraper_app_info` | Info | Job scraper application information |

### System Metrics (Node Exporter)

Standard system metrics including CPU, memory, disk, and network usage.

### Database Metrics (PostgreSQL Exporter)

PostgreSQL metrics including connection count, transaction rate, query performance, and more.

### Redis Metrics (Redis Exporter)

Redis metrics including memory usage, connected clients, operations per second, and more.

### Container Metrics (cAdvisor)

Container metrics including CPU, memory, network, and filesystem usage for all containers.

## Custom Dashboards

The monitoring setup includes a pre-configured Grafana dashboard for the Job Scraper:

- **Job Scraper Dashboard**: Overall view of the scraping process, including job statistics, performance metrics, and resource usage.

### Creating Custom Dashboards

1. Log in to Grafana at http://localhost:3000
2. Click on "Create" > "Dashboard"
3. Add panels using Prometheus as the data source
4. Save the dashboard

## Alerting

To set up alerting:

1. Configure alert rules in Prometheus or Grafana
2. Set up notification channels in Grafana (email, Slack, etc.)
3. Create alert rules based on metric thresholds

Example alert rules:

- Job scraper errors exceed a threshold in the last hour
- Scraper hasn't run successfully in the last day
- Database connection failures
- High memory or CPU usage

## Maintenance

### Backing up Grafana Dashboards

Export dashboards from the Grafana UI or use the API:

```bash
curl -X GET http://admin:admin@localhost:3000/api/dashboards/uid/job-scraper-dashboard -o dashboard-backup.json
```

### Scaling Prometheus Storage

Modify the `docker-compose.monitoring.yml` file to increase storage allocation:

```yaml
prometheus:
  volumes:
    - prometheus_data:/prometheus  # Increase this volume size
```

### Log Rotation

Configure log rotation for Prometheus and Grafana to manage disk space:

```bash
docker exec -it job-scraper-prometheus promtool tsdb clean --delete.older-than=30d /prometheus
```

## Troubleshooting

### Checking Prometheus Targets

1. Access Prometheus UI at http://localhost:9090
2. Go to Status > Targets to verify all exporters are up

### Common Issues

- **Metrics not showing in Grafana**: Check Prometheus targets and ensure the Job Scraper application is exposing metrics on the `/metrics` endpoint
- **High resource usage**: Review retention periods and adjust as needed
- **Missing data points**: Check scrape_interval and evaluation_interval in prometheus.yml 