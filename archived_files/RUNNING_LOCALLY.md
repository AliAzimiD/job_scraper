# Running the Job Scraper Application Locally

This document provides detailed instructions on how to run and test the job scraper application in a local development environment using the `test_locally.sh` script.

## Prerequisites

Before running the application locally, ensure you have:

1. **Docker** and **Docker Compose** installed and running
2. **Git** to clone the repository
3. Bash shell environment (Linux/Mac/WSL on Windows)
4. At least 4GB of free RAM and 2GB of free disk space

## Running the Application

### Step 1: Clone the Repository (if you haven't already)

```bash
git clone https://github.com/yourusername/job-scraper.git
cd job-scraper
```

### Step 2: Make the Script Executable

```bash
chmod +x test_locally.sh
```

### Step 3: Run the Script

```bash
./test_locally.sh
```

## What the Script Does

The `test_locally.sh` script automates the setup and launch of a complete development environment:

1. **Checks if Docker is running** and exits with an error if it's not
2. **Creates required directories** if they don't exist:
   - `./secrets`: For storing sensitive information
   - `./config`: For configuration files
   - `./backups`: For storing database backups
   - `./uploads`: For file uploads during data import
   - `./monitoring`: For Prometheus configuration
   - `./tests`: For test scripts
   - `./src/templates`: For web interface templates

3. **Creates sample configuration files** if they don't exist:
   - `api_config.yaml`: Contains API settings, request defaults, and scraper parameters
   - `prometheus.yml`: Basic configuration for monitoring

4. **Builds and starts Docker containers** using `docker-compose.dev.yml`:
   - `scraper`: The main job scraper service
   - `web`: Flask web interface for managing the application
   - `db`: PostgreSQL database for storing job data
   - `pgadmin`: Web-based PostgreSQL admin panel

5. **Checks if services are running** and provides status information
6. **Displays access information** for all services

## Accessing the Services

After running the script, you can access:

1. **Web Interface**: http://localhost:5000
   - Dashboard for job statistics
   - Controls to start and stop the scraper
   - Data export and import functionality
   - Backup and restore features

2. **Health Check**: http://localhost:8081/health
   - Status information about the scraper service

3. **PGAdmin**: http://localhost:5050
   - Email: admin@example.com
   - Password: devpassword
   - Use this to explore and query the database directly

4. **Database Connection** (for local tools):
   - Host: localhost
   - Port: 5432
   - Database: jobsdb
   - Username: jobuser
   - Password: devpassword

## Performing a Test Scrape

Once the environment is running:

1. Navigate to the web interface at http://localhost:5000
2. Go to the Dashboard
3. In the "Start Scraper" section, set the number of pages to scrape (start with 1-2 for testing)
4. Click the "Start Scraper" button
5. Monitor the status in the "Scraper Status" section

## Stopping the Environment

When you're done testing, you can:

1. Press `Ctrl+C` in the terminal where `test_locally.sh` is running to stop viewing logs
2. The cleanup function will automatically stop all containers when you exit the script

Alternatively, to manually stop all containers:

```bash
docker-compose -f docker-compose.dev.yml down
```

## Troubleshooting

- **Docker Not Running**: Ensure Docker is started before running the script
- **Port Conflicts**: If ports 5000, 5050, 5432, or 8081 are already in use, modify the port mappings in `docker-compose.dev.yml`
- **Container Failures**: Check container logs with `docker logs job_scraper_dev` (or other container names)
- **Permission Issues**: Ensure your user has permissions to create directories and run Docker commands

### Common Errors and Solutions

#### Package Installation Errors

If you see errors related to package installation:

```
ERROR: file:///app does not appear to be a Python project: neither 'setup.py' nor 'pyproject.toml' found.
```

Make sure the script has created the `setup.py` file. If not, manually create it:

```bash
cat > ./setup.py << EOF
from setuptools import setup, find_packages

setup(
    name="job_scraper",
    version="0.1.0",
    packages=find_packages(),
)
EOF
```

#### Web Interface Fails to Start

If the web interface container fails to start, check the logs for syntax errors:

```bash
docker logs job_web_dev
```

Common issues include:
- Async/await syntax errors: Make sure async code is properly enclosed in async functions
- Missing dependencies: Ensure all required packages are in requirements.txt
- File permission issues: Check that generated files have correct permissions

#### NumPy/Pandas Version Conflicts

If you see errors related to NumPy and pandas version conflicts:

```
ValueError: numpy.dtype size changed, may indicate binary incompatibility
```

Try specifying exact versions in your requirements.txt:

```
numpy==1.24.3
pandas==2.0.3
```

#### Database Connection Issues

If the application cannot connect to the database:

1. Check if the database container is running: `docker ps | grep job_db_dev`
2. Verify database credentials in docker-compose.dev.yml match what the application is using
3. Make sure the database port is correctly exposed and not conflicting with other services

#### Missing Templates

If you see Flask template errors, ensure the templates directory structure is correctly set up:

```bash
mkdir -p ./src/templates
```

For a quick fix, you can restart all containers:

```bash
docker-compose -f docker-compose.dev.yml down
./test_locally.sh
```

#### Missing Dependencies

If you encounter errors about missing Python modules:

```
ModuleNotFoundError: No module named 'tenacity'
ModuleNotFoundError: No module named 'sqlalchemy'
```

You need to update the requirements.txt file to include these dependencies:

```bash
# Add to requirements.txt
sqlalchemy==1.4.48
tenacity==8.2.2
```

Then rebuild the containers:

```bash
docker-compose -f docker-compose.dev.yml down
docker-compose -f docker-compose.dev.yml up --build -d
```

#### Initial Setup Issues

If the application doesn't set up properly on the first run, try:

1. Cleaning up the Docker environment:
   ```bash
   docker-compose -f docker-compose.dev.yml down -v
   ```

2. Removing generated files:
   ```bash
   rm -f setup.py
   ```

3. Running the setup script again:
   ```bash
   ./test_locally.sh
   ```

#### Container Exit Problems

If containers exit unexpectedly, check if commands are failing. You can modify the commands in docker-compose.dev.yml to continue running even if a specific command fails:

```yaml
command: >
  /bin/bash -c "
    python -m pip install -e . || true
    python -m pytest -xvs tests/ || true
    tail -f /dev/null
  "
```

For a quick fix, you can restart all containers: 