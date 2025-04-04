# Job Scraper with Normalized Database

A comprehensive job scraping and analysis system with a normalized database schema for improved performance and data integrity.

## Overview

The Job Scraper is a system that collects job postings from various sources and stores them in a PostgreSQL database. This implementation features a normalized database schema that provides:

- Improved query performance
- Better data integrity
- Enhanced analytics capabilities
- Reduced data redundancy
- More efficient storage utilization

## System Architecture

The system consists of the following components:

- **Job Scraper Service**: Python-based service that collects job data
- **PostgreSQL Database**: Stores job data in a normalized schema
- **PgAdmin**: Web interface for database administration
- **Superset**: Analytics dashboard for visualizing job data

## Directory Structure

The project is organized into the following directories:

- **`config/`**: Configuration files for the Job Scraper
- **`docker/`**: Alternative Docker Compose configurations
- **`init-db/`**: Database initialization scripts
- **`job_data/`**: Data collected by the Job Scraper
- **`migrations/`**: Database migration scripts
- **`scripts/`**: Utility scripts for installation and maintenance
- **`secrets/`**: Secret files for database and service credentials
- **`src/`**: Source code for the Job Scraper
- **`superset/`**: Superset configuration files
- **`archive/`**: Archived/outdated files

## Database Schema

The database follows a normalized design with these main tables:

- `jobs`: Primary table storing job postings
- `companies`: Stores company information
- `job_tags`: Dictionary of job tags
- `jobs_tags`: Join table linking jobs and tags
- `job_categories`: Dictionary of job categories
- `jobs_categories`: Join table linking jobs and categories
- `locations`: Dictionary of locations
- `job_locations`: Join table linking jobs and locations
- `work_types`: Dictionary of work types
- `job_work_types`: Join table linking jobs and work types

Additional features include:

- Materialized views for analytics
- Table partitioning for improved performance
- GIN indexes for text search
- Row-level security for data protection

## Installation

### Prerequisites

- Docker and Docker Compose
- 4GB+ RAM
- 20GB+ disk space

### Standard Installation

To install the system:

```bash
# Clone the repository (if needed)
git clone https://github.com/example/job_scraper.git
cd job_scraper

# Run the installation script
./install.sh
```

The installation script will:
1. Check prerequisites
2. Set up secrets
3. Clean up existing Docker resources
4. Deploy the database and run migrations
5. Start all services

### Alternative Installation (Database Only)

If you encounter any issues with the standard installation, you can use the simplified database setup:

```bash
# Run the simplified database setup
./scripts/setup-db.sh
```

This will:
1. Set up just the PostgreSQL database
2. Apply all migrations
3. Provide connection details

## Usage

### Accessing Services

After installation, you can access the following services:

- **Job Scraper API**: http://localhost:8081
- **PgAdmin**: http://localhost:5050
  - Email: admin@example.com
  - Password: admin
- **Superset**: http://localhost:8088
  - Username: admin
  - Password: admin

### Database Connection

To connect to the database directly:

```bash
docker exec -it job_db psql -U jobuser -d jobsdb
```

Or use your favorite PostgreSQL client with these details:
- Host: localhost
- Port: 5432
- Database: jobsdb
- Username: jobuser
- Password: (stored in secrets/db_password.txt)

## Analytics

The system includes several materialized views for analytics:

- `mv_job_stats_by_company`: Job statistics grouped by company
- `mv_job_stats_by_tag`: Job statistics grouped by tag
- `mv_job_stats_by_category`: Job statistics grouped by category
- `mv_job_stats_by_location`: Job statistics grouped by location
- `mv_tag_co_occurrence`: Analysis of tags that appear together
- `mv_category_tag_relationship`: Analysis of category-tag relationships
- `mv_job_posting_trends`: Job posting trends over time

## Utility Scripts

The `scripts/` directory contains utility scripts for managing the system:

- **Installation and Setup**:
  - `setup-db.sh`: Sets up only the database (useful for development)
  - `setup-minimal.sh`: Minimal setup with just the database and PgAdmin

- **Maintenance Scripts**:
  - `cleanup.sh`: Stops and removes all Docker resources
  - `run-migrations.sh`: Runs only the database migrations
  - `start-db.sh`: Starts only the database container

## Troubleshooting

### Common Issues

1. **Container Configuration Errors**
   - Run `./scripts/cleanup.sh` to remove all containers and volumes
   - Then run `./scripts/setup-db.sh` to set up just the database
   - Finally, try `./install.sh` again

2. **Database Migration Issues**
   - Check the migration logs: `docker logs job_db`
   - Connect to the database and check the status of tables

3. **Service Connectivity Issues**
   - Ensure ports are not in use by other applications
   - Check Docker network configuration

### Logs

To view logs for any service:

```bash
docker logs job_scraper # For the scraper service
docker logs job_db # For the database service
docker logs job_pgadmin # For PgAdmin
docker logs job_superset # For Superset
```

## Maintenance

### Database Backups

To backup the database:

```bash
docker exec -t job_db pg_dump -U jobuser jobsdb > backups/backup_$(date +%Y%m%d).sql
```

### Updating the System

To update the system:

```bash
git pull # Get the latest code
./install.sh # Run the installation script again
```

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Contributing

Contributions are welcome! Please see CONTRIBUTING.md for details on how to contribute.

# Job Scraper Admin Dashboard

A comprehensive admin dashboard for monitoring and controlling the Job Scraper application.

## Features

- Real-time monitoring of scraping status and statistics
- View and filter scraper logs
- Configure scraper settings through a user-friendly interface
- Start and stop scraping operations manually
- View recent job listings collected by the scraper

## Setup Instructions

### Prerequisites

- Python 3.6 or higher
- FastAPI
- Uvicorn
- Python-multipart

### Installation

1. Clone the repository (if you haven't already):
   ```bash
   git clone [your-repository-url]
   cd job_scraper
   ```

2. Run the setup script:
   ```bash
   ./scripts/setup_admin.sh
   ```

   This script will:
   - Create necessary directories
   - Install required dependencies
   - Set up default admin UI files if they don't exist

3. If you prefer to install dependencies manually:
   ```bash
   pip install fastapi uvicorn python-multipart
   ```

### Running the Dashboard

1. Start the FastAPI server:
   ```bash
   python3 src/main.py
   ```

2. Access the admin dashboard in your browser:
   ```
   http://localhost:8000/admin
   ```

## Dashboard Sections

### Status Panel
- Shows if scraping is active or idle
- Displays the last scrape time
- Shows total jobs collected
- Provides buttons to start and stop scraping operations

### Recent Jobs Panel
- Displays the most recent jobs collected by the scraper
- Shows job title, company, location, and date

### Configuration Panel
- View and update scraper configuration settings
- Changes are applied immediately

### Logs Panel
- Real-time view of scraper logs
- Auto-refreshes to show the latest logs

## API Endpoints

The dashboard interacts with the following API endpoints:

- `GET /api/stats` - Get current scraper statistics
- `GET /api/logs` - Get scraper logs
- `GET /api/config` - Get current configuration
- `POST /api/config` - Update configuration
- `POST /api/scrape/start` - Start a scraping job
- `POST /api/scrape/stop` - Stop the current scraping job

## Customization

You can customize the dashboard by modifying the following files:

- `/public/admin/index.html` - Main dashboard structure
- `/public/admin/css/admin.css` - Dashboard styling
- `/public/admin/js/admin.js` - Dashboard functionality

## Troubleshooting

If you encounter issues with the admin dashboard:

1. Ensure the FastAPI server is running
2. Check that all required packages are installed
3. Verify that the admin routes are properly configured in `main.py`
4. Check the browser console for JavaScript errors
5. Examine the server logs for API errors

## License

[Your License Information]

## Admin Dashboard

The Job Scraper now includes a comprehensive admin dashboard for monitoring and controlling the scraping system.

### Dashboard Features

- Real-time monitoring of scraping status and statistics
- View and filter scraper logs
- Configure scraper settings through a user-friendly interface
- Start and stop scraping operations manually
- View recent job listings collected by the scraper

### Running the Admin Dashboard

#### Method 1: Direct Execution

```bash
# Using the dedicated script
./run_admin_dashboard.py

# Or with options
./run_admin_dashboard.py --port 8082 --reload
```

#### Method 2: Docker

```bash
# Using the Docker script
./scripts/run_admin_docker.sh
```

### Accessing the Dashboard

Once running, access the dashboard at:

```
http://localhost:8081/admin
```

The dashboard will show the current status of the scraper, recent logs, and configuration options.

### Dashboard Setup

If you need to set up the dashboard manually:

```bash
./scripts/setup_admin.sh
```

For more detailed information, see [the admin dashboard documentation](docs/admin_dashboard.md).

# Job Scraper with Admin Dashboard

A powerful job scraping application with an administrative dashboard for monitoring and controlling the scraping process.

## Features

- Web-based admin dashboard for monitoring and controlling job scraping
- Configurable job sources and scraping schedule
- Real-time logs and statistics
- RESTful API for programmatic access
- Containerized deployment support

## Installation

### Prerequisites

- Python 3.6+
- pip (Python package manager)
- Docker (optional, for containerized deployment)

### Standard Installation

1. Clone the repository:
   ```
   git clone <repository-url>
   cd job_scraper
   ```

2. Install the required dependencies:
   ```
   pip install -r requirements.txt
   ```

3. Set up the admin dashboard:
   ```
   chmod +x scripts/setup_admin.sh
   ./scripts/setup_admin.sh
   ```

## Running the Application

### Running the Admin Dashboard

To start the admin dashboard, run:

```
python run_admin_dashboard.py
```

By default, the dashboard will be available at `http://localhost:8081/admin`

Options:
- `--host`: Host to bind the server (default: 0.0.0.0)
- `--port`: Port to bind the server (default: 8081)
- `--reload`: Enable auto-reload for development (default: False)

Example with custom port:
```
python run_admin_dashboard.py --port 8089
```

### Running with Docker

1. Build and start the containers:
   ```
   docker-compose up -d
   ```

2. Access the admin dashboard at `http://localhost:8081/admin`

## API Endpoints

The application exposes the following API endpoints:

- `GET /api/stats` - Get current scraper statistics
- `GET /api/config` - Get current configuration
- `POST /api/config` - Update configuration
- `GET /api/logs` - Get scraper logs
- `POST /api/control/start` - Start the scraper
- `POST /api/control/stop` - Stop the scraper

## Development

### Testing

Run the tests with:

```
python -m pytest
```

### Test Server

For quick testing of the API, you can use the test server:

```
python test_server.py
```

This will start a minimal FastAPI server on port 8089.

## Troubleshooting

### Port Already in Use

If you encounter a "Port already in use" error, either:
1. Choose a different port: `python run_admin_dashboard.py --port 8090`
2. Find and stop the process using the port:
   ```
   netstat -tulpn | grep <port>
   kill <pid>
   ```

### Static Files Not Loading

If the admin dashboard UI isn't loading properly, ensure the setup script was run:
```
chmod +x scripts/setup_admin.sh
./scripts/setup_admin.sh
```

## License

[MIT License](LICENSE)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.