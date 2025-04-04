# Job Scraper Admin Dashboard

This documentation provides detailed information about the Job Scraper Admin Dashboard, its features, configuration, and troubleshooting.

## Table of Contents

1. [Overview](#overview)
2. [Installation](#installation)
3. [Dashboard Components](#dashboard-components)
4. [Running the Dashboard](#running-the-dashboard)
5. [API Reference](#api-reference)
6. [Customization](#customization)
7. [Troubleshooting](#troubleshooting)
8. [Docker Deployment](#docker-deployment)

## Overview

The Job Scraper Admin Dashboard is a web-based interface for monitoring and controlling the job scraping system. It provides:

- Real-time status monitoring
- Job scraping control (start/stop)
- Configuration management
- Log viewing
- Recent job listings display

## Installation

### Prerequisites

- Python 3.6+
- Required packages: `fastapi`, `uvicorn`, `python-multipart`

### Standard Installation

1. Set up the admin UI files:

```bash
chmod +x scripts/setup_admin.sh
./scripts/setup_admin.sh
```

2. Install required Python packages:

```bash
pip install -r requirements.txt
```

## Dashboard Components

### Status Panel

The Status Panel shows:
- Current scraper status (Running/Idle)
- Total jobs scraped
- Last scrape time
- Control buttons for starting and stopping the scraper

### Recent Jobs Panel

Displays the most recently scraped jobs with:
- Job title
- Company name
- Location
- Posted date

### Configuration Panel

Allows viewing and editing of the scraper configuration:
- Schedule settings
- Sources configuration
- Scraping limits and parameters

### Logs Panel

Shows the most recent logs from the scraper with:
- Timestamp
- Log level
- Message
- Configurable limit for number of logs to display

## Running the Dashboard

### Using the Management Script

The easiest way to run and manage the dashboard is using the admin dashboard manager script:

```bash
# Start the dashboard
./scripts/admin_dashboard_manager.sh start

# Check status
./scripts/admin_dashboard_manager.sh status

# View logs
./scripts/admin_dashboard_manager.sh logs 100

# Stop the dashboard
./scripts/admin_dashboard_manager.sh stop
```

### Manual Execution

You can also run the dashboard manually:

```bash
python run_admin_dashboard.py --port 8081 --host 0.0.0.0
```

Command-line options:
- `--port`: Port to run the dashboard on (default: 8081)
- `--host`: Host to bind to (default: 0.0.0.0)
- `--reload`: Enable auto-reload for development (default: False)

### Using Docker

For containerized deployment:

```bash
./scripts/run_admin_docker.sh
```

This will start the admin dashboard in a Docker container.

## API Reference

The dashboard interacts with the following API endpoints:

### Status and Monitoring

- `GET /api/stats` - Get current statistics including running status, job count, and recent jobs
- `GET /api/logs` - Get scraper logs (accepts `limit` parameter)

### Configuration

- `GET /api/config` - Get current configuration
- `POST /api/config` - Update configuration (requires JSON body with configuration)

### Control

- `POST /api/scrape/start` - Start a scraping job
- `POST /api/scrape/stop` - Stop the current scraping job

## Customization

### UI Customization

The dashboard UI is customizable through CSS and JavaScript files:

- `public/admin/css/admin.css` - Main stylesheet
- `public/admin/js/admin.js` - Dashboard functionality

### Adding New Features

To add new features to the dashboard:

1. Extend the API in `src/admin_api.py`
2. Add new routes in `src/admin_routes.py`
3. Update the UI in the HTML and JavaScript files

## Troubleshooting

### Port Conflicts

If you encounter "Address already in use" errors:

```bash
# Check if the port is in use
./scripts/manage_ports.sh check 8081

# Free the port if needed
./scripts/manage_ports.sh free 8081

# Start with a different port
./scripts/admin_dashboard_manager.sh start 8090
```

### Missing Dependencies

If you see import errors:

```bash
pip install -r requirements.txt
```

### Static Files Not Loading

If the dashboard UI looks unstyled:

```bash
# Run the setup script again
./scripts/setup_admin.sh
```

### Database Connection Issues

If you see database connection errors:

1. Check that the database is running
2. Verify connection settings in the configuration file
3. Ensure database migrations have been applied

## Docker Deployment

### Running with Docker Compose

Use the provided Docker Compose configuration:

```bash
docker-compose -f docker/docker-compose.admin.yml up -d
```

### Environment Variables

When running in Docker, you can configure the dashboard using:

- `ADMIN_PORT` - Dashboard port (default: 8081)
- `DB_HOST` - Database host
- `DB_PORT` - Database port
- `DB_USER` - Database username
- `DB_NAME` - Database name
- `DB_PASSWORD_FILE` - Path to file containing database password 