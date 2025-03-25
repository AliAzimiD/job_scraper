# Job Scraper Application

A full-featured job scraper application built with Python Flask, PostgreSQL, and Redis.

## Overview

The Job Scraper application is designed to scrape job listings from various job boards, store them in a PostgreSQL database, and provide a web interface for browsing, searching, and exporting the collected data.

## Key Features

- **Job Scraping**: Automated scraping of job listings from multiple sources
- **Web Interface**: Flask-based dashboard to view, search, and manage job listings
- **Data Export/Import**: Export job data to CSV/JSON and import from external sources
- **Monitoring**: Integrated health checks and Prometheus metrics for observability
- **Containerization**: Docker setup for easy deployment and scaling

## Architecture

The application follows a modular architecture with the following components:

- **Web Interface**: Flask application with templates and static assets
- **Scraper Module**: Core scraping functionality with configurable job sources
- **Database Layer**: PostgreSQL storage with SQLAlchemy ORM
- **Caching Layer**: Redis for performance optimization
- **Monitoring**: Prometheus metrics and health check endpoints

## Prerequisites

- Python 3.10+
- PostgreSQL 13+
- Redis 6+
- Docker and Docker Compose (for containerized deployment)

## Installation

### Local Development Setup

1. Clone the repository:

   ```bash
   git clone https://github.com/yourusername/job-scraper.git
   cd job-scraper
   ```

2. Create and activate a virtual environment:

   ```bash
   python3 -m venv venv
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   ```

3. Install dependencies:

   ```bash
   pip install -r requirements.txt
   ```

4. Set up environment variables:

   ```bash
   cp .env.example .env
   # Edit .env with your configuration values
   ```

5. Initialize the database:

   ```bash
   # Ensure PostgreSQL is running
   python3 -m app.db.init_db
   ```

6. Run the application:

   ```bash
   python3 main.py
   ```

### Docker Deployment

1. Build and start containers:

   ```bash
   docker-compose up -d
   ```

2. Access the application at <http://localhost:5000>

## Usage

### Web Interface

The web interface provides the following features:

- **Dashboard**: Overview of scraping status and job statistics
- **Job Listings**: Browse and search collected job listings
- **Export**: Export job data to various formats
- **Import**: Import job data from external sources
- **Scraper Control**: Start, stop, and monitor scraping jobs

### API Endpoints

The application exposes the following API endpoints:

- `GET /api/jobs`: Get a list of jobs with optional filtering
- `GET /api/jobs/{id}`: Get details for a specific job
- `POST /api/start-scrape`: Start a new scraping job
- `POST /api/stop-scrape`: Stop the current scraping job
- `GET /api/status`: Get the current status of the scraper
- `GET /api/export`: Export job data to CSV/JSON
- `POST /api/import`: Import job data from an external source
- `GET /health`: Health check endpoint
- `GET /metrics`: Prometheus metrics endpoint

## Configuration

Configuration is managed through YAML files in the `config/` directory:

- `app_config.yaml`: General application settings
- `api_config.yaml`: API-specific settings
- `logging_config.yaml`: Logging configuration

Environment-specific settings can be overridden using environment variables defined in the `.env` file.

## Monitoring and Observability

The application includes built-in monitoring capabilities:

- **Health Checks**: `/health` endpoint for application health status
- **Prometheus Metrics**: `/metrics` endpoint for Prometheus metrics
- **Structured Logging**: Detailed logs using the Python logging module

## Database Structure

The core database tables include:

- `jobs`: Stores job listings with details like title, company, location, etc.
- `companies`: Information about companies posting jobs
- `scrape_runs`: Records of scraping jobs with timestamps and statistics
- `users`: User accounts for the web interface (if authentication is enabled)

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the LICENSE file for details.

## Acknowledgements

- [Beautiful Soup](https://www.crummy.com/software/BeautifulSoup/) for HTML parsing
- [Flask](https://flask.palletsprojects.com/) for the web framework
- [SQLAlchemy](https://www.sqlalchemy.org/) for database ORM
- [Prometheus](https://prometheus.io/) for metrics collection
- [Bootstrap](https://getbootstrap.com/) for the web interface
