# Job Scraper Application

A modern, well-structured application for scraping job postings from various sources, storing them in a PostgreSQL database, and providing a web interface and API for data management and analysis.

## Features

- Asynchronous job scraping with rate limiting and retry logic
- RESTful API for job data management
- Web interface with dashboard for statistics and management
- **Advanced job search with filtering and export options**
- **Advanced data visualization with Apache Superset integration**
- Data export/import in various formats (JSON, CSV, Parquet, Excel)
- Database backup and restore functionality
- **Robust error handling with retry logic and fallback mechanisms**
- **Enhanced data validation for job entries**
- **User-friendly configuration interface**
- Comprehensive error handling and logging
- Authentication for API endpoints
- Containerized with Docker and Docker Compose

## Requirements

- Python 3.10+
- PostgreSQL 13+
- Docker and Docker Compose (optional)

## Project Structure

The application follows a modular, clean architecture approach:

```
job-scraper/
├── config/                  # Configuration files
│   └── api_config.yaml      # Main application configuration
├── docker/                  # Docker-related files
│   ├── Dockerfile           # Application Dockerfile
│   └── postgres/            # PostgreSQL initialization scripts
├── init-db/                 # Database initialization scripts
├── scripts/                 # Utility scripts
├── src/                     # Source code
│   ├── static/              # Static assets
│   ├── templates/           # HTML templates
│   │   ├── base.html        # Base template
│   │   ├── dashboard.html   # Dashboard template
│   │   ├── search.html      # Job search interface
│   │   ├── job_details.html # Job details view
│   │   └── scraper_config.html # Scraper configuration interface
│   ├── config_manager.py    # Configuration management
│   ├── data_manager.py      # Data export/import management
│   ├── db_manager.py        # Database connection management
│   ├── filters.py           # Template filters
│   ├── log_setup.py         # Logging configuration
│   ├── scraper.py           # Job scraper logic
│   └── web_app.py           # Flask web application
├── tests/                   # Test suite
├── .env.example             # Example environment variables
├── docker-compose.yml       # Docker Compose configuration
├── Dockerfile               # Production Dockerfile
├── Dockerfile.dev           # Development Dockerfile
├── README.md                # This file
└── requirements.txt         # Python dependencies
```

## Installation

### Using Docker (Recommended)

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/job-scraper.git
   cd job-scraper
   ```

2. Create a `.env` file from the example:
   ```bash
   cp .env.example .env
   ```

3. Edit the `.env` file with your settings.

4. Build and start the containers:
   ```bash
   docker-compose up -d
   ```

The application will be available at http://localhost:5000

### Manual Installation

1. Clone the repository:
   ```bash
   git clone https://github.com/yourusername/job-scraper.git
   cd job-scraper
   ```

2. Create and activate a virtual environment:
   ```bash
   python -m venv venv
   source venv/bin/activate  # On Windows: venv\Scripts\activate
   ```

3. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```

4. Set up PostgreSQL database:
   ```bash
   createdb jobsdb
   ```

5. Create a `.env` file with your configuration:
   ```
   FLASK_ENV=development
   FLASK_DEBUG=True
   POSTGRES_HOST=localhost
   POSTGRES_PORT=5432
   POSTGRES_DB=jobsdb
   POSTGRES_USER=your_username
   POSTGRES_PASSWORD=your_password
   FLASK_SECRET_KEY=generate_a_random_secret_key
   API_USERNAME=api_user
   API_PASSWORD=secure_password
   ```

6. Run the application:
   ```bash
   python -m src.main
   ```

## Usage

### Web Interface

The application provides a web interface with the following sections:

- **Dashboard**: Overview of job statistics and recent job listings
- **Search Jobs**: Advanced job search with filtering and export options
- **Scraper Control**: Start, stop, and monitor job scraping operations
- **Data Management**: Export, import, backup, and restore job data
- **Configure Scraper**: User-friendly configuration interface

Access the web interface at http://localhost:5000

### Search Interface

The search interface allows you to find jobs using various criteria:

- **Keyword**: Search in job titles and descriptions
- **Location**: Filter by location
- **Company**: Filter by company name
- **Posted Within**: Filter by posting date (last 24 hours, 7 days, 30 days, etc.)
- **Sort By**: Sort results by date, relevance, or company
- **Results Per Page**: Control the number of results displayed

Search results can be exported in CSV, JSON, or Excel formats with a single click.

### Scraper Configuration

The scraper configuration interface allows you to adjust settings without editing files:

- **Request Settings**: Max pages, batch size, timeout, user agent, etc.
- **Retry & Error Handling**: Retry counts, delay, failure thresholds
- **Storage Options**: Raw data storage options

### API

The application provides a RESTful API for programmatic access:

#### Authentication

All API endpoints (except health check) require Basic Authentication.

#### Endpoints

- `GET /api/health`: Health check endpoint
- `GET /api/jobs`: Get job listings with filters
- `GET /api/jobs/<job_id>`: Get a specific job
- `POST /api/jobs`: Create a new job
- `GET /api/stats`: Get job statistics
- `GET /api/search`: Advanced job search
- `GET /export_search/<format>`: Export search results in various formats

Detailed API documentation is available at http://localhost:5000/docs when the application is running.

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `FLASK_ENV` | Application environment | `production` |
| `FLASK_DEBUG` | Enable debug mode | `False` |
| `FLASK_HOST` | Host to bind | `0.0.0.0` |
| `FLASK_PORT` | Port to bind | `5000` |
| `POSTGRES_HOST` | PostgreSQL host | `localhost` |
| `POSTGRES_PORT` | PostgreSQL port | `5432` |
| `POSTGRES_DB` | PostgreSQL database name | `jobsdb` |
| `POSTGRES_USER` | PostgreSQL username | `jobuser` |
| `POSTGRES_PASSWORD` | PostgreSQL password | `devpassword` |
| `DATABASE_URL` | Full database URL (overrides individual settings) | |
| `LOG_LEVEL` | Logging level | `INFO` |
| `LOG_DIR` | Directory for log files | `logs` |
| `CONFIG_PATH` | Path to configuration file | `config/api_config.yaml` |

### Configuration File

The application uses a YAML configuration file for scraper settings and other options. See `config/api_config.yaml` for details. Configuration can be modified through the web interface or by editing the file directly.

## Error Handling and Resilience

The application includes several mechanisms to ensure data integrity and operational resilience:

- **Connection Retry**: Automatic reconnection to database with exponential backoff
- **Job Processing Retry**: Multiple attempts for job insertion with increasing delay
- **Data Validation**: Comprehensive validation of job data before database insertion
- **Fallback Mechanisms**: Jobs are saved to disk if database operations fail
- **Sample Data Preservation**: Problematic jobs are stored separately for debugging
- **Detailed Logging**: Comprehensive logging of errors and operations
- **Performance Metrics**: Tracking of processing time and success rates

## Development

### Running Tests

```bash
pytest
```

### Running with Debug Mode

```bash
FLASK_DEBUG=True python -m src.main
```

### Code Quality

This project follows PEP 8 style guidelines and uses:

- Black for code formatting
- isort for import sorting
- flake8 for linting
- mypy for type checking

You can run all checks with:

```bash
black src tests
isort src tests
flake8 src tests
mypy src
```

## Recent Improvements

Recent enhancements to the application include:

1. **Advanced Search Interface**: User-friendly search with multiple filtering options
2. **Job Details View**: Comprehensive view of job details with formatting
3. **Export Functionality**: Export search results in multiple formats
4. **Configuration UI**: Web interface for adjusting scraper settings
5. **Improved Error Handling**: Robust retry logic with fallback mechanisms
6. **Enhanced Data Validation**: Better validation of job data before storage
7. **Template Filters**: Formatting of dates, currencies, and other data
8. **Dashboard Enhancements**: Quick search and better layout

## Analytics with Apache Superset

The application includes integration with Apache Superset for advanced data visualization and analytics:

### Features

- **Interactive Dashboards**: Explore job data with pre-built interactive dashboards
- **Custom SQL Queries**: Run ad-hoc SQL queries against the job database
- **Rich Visualizations**: Create charts, graphs, and other visualizations to analyze job market trends
- **Embedded Analytics**: Access Superset dashboards directly from the main application interface
- **Custom Filters**: Filter data by date, location, company, and other fields
- **Export Options**: Export visualizations and data in various formats

### Default Dashboards

The Superset integration includes several pre-built dashboards:

1. **Job Market Trends**: Overview of job posting trends, volume, and patterns
2. **Salary Analysis**: Analysis of salary distributions across different job categories and locations
3. **Company Insights**: Company hiring patterns and job distribution

### Accessing Superset

You can access the Superset interface in two ways:

1. **Through the main application**: Navigate to the "Analytics" section in the main menu
2. **Direct access**: Access Superset directly at http://localhost:8088 (default credentials: admin/admin)

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Acknowledgements

- Thanks to all contributors who have helped improve this project
- Built with Flask, SQLAlchemy, asyncio, and other excellent open source technologies