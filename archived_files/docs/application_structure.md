# Application Structure

This document provides a comprehensive overview of the Job Scraper application structure, including the organization of modules, components, and their interactions.

## Directory Structure

The application follows a modular structure organized by feature area:

```
job-scraper/
├── app/                      # Application package
│   ├── __init__.py           # Application factory
│   ├── api/                  # API endpoints
│   │   └── __init__.py
│   ├── core/                 # Core application logic
│   │   ├── __init__.py
│   │   ├── scraper.py        # Job scraper implementation
│   │   ├── scheduler.py      # Scheduling functionality
│   │   └── data_manager.py   # Data management logic
│   ├── db/                   # Database modules
│   │   ├── __init__.py
│   │   ├── manager.py        # Database connection and operations
│   │   ├── models.py         # SQLAlchemy models
│   │   └── migrations/       # Database migration scripts
│   ├── monitoring/           # Monitoring components
│   │   ├── __init__.py
│   │   ├── metrics.py        # Prometheus metrics integration
│   │   └── health.py         # Health check endpoints
│   ├── templates/            # Jinja2 templates
│   │   └── *.html
│   ├── utils/                # Utility modules
│   │   ├── __init__.py
│   │   ├── cache.py          # Redis caching functionality
│   │   ├── config.py         # Configuration management
│   │   └── log_setup.py      # Logging configuration
│   └── web/                  # Web interface
│       ├── __init__.py
│       ├── filters.py        # Template filters
│       └── routes.py         # Web routes
├── config/                   # Configuration files
│   ├── api_config.yaml       # API configuration
│   ├── app_config.yaml       # Application configuration
│   └── logging_config.yaml   # Logging configuration
├── data/                     # Data storage
│   ├── job_data/             # Job data storage
│   └── backups/              # Backup files
├── docker/                   # Docker configurations
│   ├── app/                  # Application Docker files
│   │   └── Dockerfile        # Main application Dockerfile
│   ├── db/                   # Database Docker files
│   └── monitoring/           # Monitoring Docker files
├── docs/                     # Documentation
│   ├── database.md           # Database documentation
│   └── application_structure.md  # This file
├── logs/                     # Log files
├── scripts/                  # Utility scripts
│   ├── manage_migrations.py  # Database migration script
│   ├── test_db_connection.py # Database connection test
│   └── migrate_old_data.py   # Data migration script
├── static/                   # Static web assets
│   ├── css/                  # CSS files
│   ├── js/                   # JavaScript files
│   └── img/                  # Image files
├── tests/                    # Test suite
│   ├── unit/                 # Unit tests
│   ├── integration/          # Integration tests
│   └── e2e/                  # End-to-end tests
├── uploads/                  # File upload directory
├── docker-compose.yml        # Docker Compose configuration
├── Dockerfile                # Main Dockerfile
├── main.py                   # Application entry point
├── requirements.txt          # Python dependencies
└── README.md                 # Project documentation
```

## Key Components

### 1. Application Factory (`app/__init__.py`)

The application uses Flask's application factory pattern, which:

- Creates a Flask application instance
- Loads configuration from files or environment variables
- Registers blueprints, extensions, and routes
- Sets up error handlers and middleware
- Configures logging and monitoring

```python
from app import create_app

# Create the application
app = create_app(config_path="config/app_config.yaml")

# Run the application
if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
```

### 2. Core Logic (`app/core/`)

The core package contains the main business logic:

- **Scraper** (`scraper.py`): Implements job scraping functionality for various job sites
- **Scheduler** (`scheduler.py`): Manages scheduled scraping jobs
- **Data Manager** (`data_manager.py`): Handles data processing, transformation, and validation

### 3. Database Layer (`app/db/`)

The database layer provides:

- **Models** (`models.py`): SQLAlchemy ORM models for the database schema
- **Manager** (`manager.py`): Database connection and session management
- **Migrations** (`migrations/`): Alembic-based database migration scripts

### 4. Web Interface (`app/web/`)

The web interface provides:

- **Routes** (`routes.py`): Flask routes for the web application
- **Filters** (`filters.py`): Custom Jinja2 template filters

### 5. API Interface (`app/api/`)

The API interface offers RESTful endpoints for programmatic access.

### 6. Monitoring (`app/monitoring/`)

The monitoring components include:

- **Metrics** (`metrics.py`): Prometheus metrics collection
- **Health Checks** (`health.py`): Health check endpoints for monitoring

### 7. Utility Modules (`app/utils/`)

Utility modules provide common functionality:

- **Cache** (`cache.py`): Redis-based caching functionality
- **Config** (`config.py`): Configuration loading and management
- **Logging** (`log_setup.py`): Logging configuration

## Component Interactions

### Data Flow

The typical data flow through the application:

1. **User Request**: User interacts with the web interface or API
2. **Web/API Layer**: Request is processed by routes in `app/web/routes.py` or `app/api/`
3. **Core Logic**: Business logic in `app/core/` is executed
4. **Database Layer**: Data is retrieved or stored using models and the database manager
5. **Response**: Response is returned to the user

### Scraping Flow

The job scraping process flow:

1. **Scheduler**: Scheduled job triggers a scrape in `scheduler.py`
2. **Scraper**: The scraper in `scraper.py` fetches job listings
3. **Data Manager**: Raw data is processed in `data_manager.py`
4. **Database**: Processed jobs are stored using the database manager
5. **Metrics**: Scraping metrics are updated in `metrics.py`

## Configuration

The application uses a layered configuration approach:

1. **Default Configuration**: Built-in defaults in the application code
2. **Configuration Files**: YAML files in the `config/` directory
3. **Environment Variables**: Override configuration via environment variables

### Configuration Files

- **app_config.yaml**: General application settings
- **api_config.yaml**: API-specific configuration
- **logging_config.yaml**: Logging settings

### Environment Variables

Important environment variables:

- `FLASK_DEBUG`: Enable debug mode
- `FLASK_ENV`: Application environment (development, testing, production)
- `SECRET_KEY`: Secret key for Flask sessions
- `DATABASE_URL`: Database connection string
- `REDIS_URL`: Redis connection string
- `LOG_LEVEL`: Logging level

## Extending the Application

### Adding a New Module

To add a new module to the application:

1. Create a new directory in the appropriate package
2. Create an `__init__.py` file in the new directory
3. Implement the module functionality
4. Register the module with the application factory if necessary

### Adding a New Model

To add a new database model:

1. Add the model to `app/db/models.py`
2. Create a migration using Alembic:

   ```bash
   python scripts/manage_migrations.py create "add new model"
   ```

3. Apply the migration:

   ```bash
   python scripts/manage_migrations.py upgrade
   ```

### Adding a New API Endpoint

To add a new API endpoint:

1. Create a new route function in the appropriate API module
2. Register the route with the Flask application
3. Update API documentation

## Testing

The application includes a comprehensive test suite:

- **Unit Tests**: Test individual components in isolation
- **Integration Tests**: Test component interactions
- **End-to-End Tests**: Test the entire application

Run tests using pytest:

```bash
# Run all tests
pytest

# Run specific test file
pytest tests/unit/test_db_models.py

# Run with coverage report
pytest --cov=app tests/
```

## Deployment

The application supports multiple deployment options:

### Docker Deployment

Deploy using Docker Compose:

```bash
# Build and start containers
docker-compose up -d

# View logs
docker-compose logs -f

# Stop containers
docker-compose down
```

### Manual Deployment

1. Set up Python environment
2. Install dependencies: `pip install -r requirements.txt`
3. Set environment variables
4. Run database migrations: `python scripts/manage_migrations.py upgrade`
5. Start the application: `python main.py`

## Monitoring and Operations

The application includes a monitoring stack with:

- **Prometheus**: Metrics collection
- **Grafana**: Metrics visualization
- **Health Checks**: `/health` endpoint for automated monitoring

### Key Metrics

- Request rates and latencies
- Database query performance
- Scraper performance and success rates
- System resource utilization

### Logs

Logs are written to the `logs/` directory and follow a structured format for easy parsing and analysis.
