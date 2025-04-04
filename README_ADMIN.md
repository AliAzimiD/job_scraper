# Job Scraper Admin Dashboard - Quick Start Guide

This guide provides instructions for setting up and using the Job Scraper Admin Dashboard, a web-based interface for monitoring and controlling the job scraping system.

## Quick Start

### 1. Run the Setup Script

```bash
cd /path/to/job_scraper
./scripts/setup_admin.sh
```

This script will:
- Create the necessary directories
- Check for required dependencies
- Guide you through integration steps if needed

### 2. Start the Application

You can use the provided example:

```bash
cd /path/to/job_scraper
./examples/run_with_admin.py
```

Or run it manually:

```bash
cd /path/to/job_scraper
uvicorn src.main:app --host 0.0.0.0 --port 8081 --reload
```

### 3. Access the Dashboard

Open your browser and navigate to:

```
http://localhost:8081/admin
```

## Dashboard Overview

![Dashboard Overview](https://via.placeholder.com/800x450?text=Job+Scraper+Admin+Dashboard)

The dashboard is divided into several panels:

1. **Status Panel**: Shows the current scraper status and controls
2. **Recent Jobs**: Displays recently scraped jobs
3. **Configuration**: View and update scraper settings
4. **Logs**: View recent scraper logs

## Common Tasks

### Starting a Manual Scrape

1. Navigate to the Status panel
2. Click the "Start Scrape" button
3. Monitor progress in the logs panel

### Updating Configuration

1. Navigate to the Configuration panel
2. Modify settings as needed
3. Click "Save Configuration"

### Viewing Logs

1. Navigate to the Logs panel
2. Use the "Refresh" button to get the latest logs
3. Adjust the limit if you need to see more entries

## Customization

For detailed customization options, see the [full documentation](docs/admin_dashboard.md).

## Troubleshooting

If you encounter issues:

1. Check that all dependencies are installed with `pip install fastapi uvicorn python-multipart`
2. Verify that your main.py includes the admin routes and static file setup
3. Check server logs for detailed error messages

## Security Note

The dashboard does not include authentication by default. For production use, consider implementing authentication and access controls.

## Full Documentation

For complete documentation, see [docs/admin_dashboard.md](docs/admin_dashboard.md). 