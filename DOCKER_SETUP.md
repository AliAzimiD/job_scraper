# Job Scraper Docker Setup Guide

This guide explains how to set up and use the Docker environment for the Job Scraper application.

## Quick Start

To get started quickly, simply run:

```bash
cd /root/karchi/job_scraper
./scripts/manage_services.sh start
```

This will start all services. To check the status:

```bash
./scripts/dashboard_status.sh
```

## Available Scripts

The project includes several useful scripts:

### Service Management

`scripts/manage_services.sh` - Manages Docker services

```bash
# Usage examples
./scripts/manage_services.sh start           # Start all services
./scripts/manage_services.sh logs test       # Show logs of test server
./scripts/manage_services.sh restart admin   # Restart admin service
./scripts/manage_services.sh status          # Show status of all services
./scripts/manage_services.sh clean           # Clean up (stop and remove containers)
```

### Status Dashboard

`scripts/dashboard_status.sh` - Checks and displays the status of all components

```bash
./scripts/dashboard_status.sh
```

## Service Endpoints

| Service | URL | Description |
|---------|-----|-------------|
| Test Server | http://localhost:8089/ | Simple test server |
| Test Server Health | http://localhost:8089/health | Health check endpoint |
| Admin Dashboard | http://localhost:8081/admin | Admin UI |
| Admin API Stats | http://localhost:8081/api/stats | Statistics API |
| Admin API Logs | http://localhost:8081/api/logs | Logs API |
| Admin API Config | http://localhost:8081/api/config | Configuration API |

## Docker Compose Setup

The project uses Docker Compose to manage containers. The main configuration file is at `/root/karchi/job_scraper/docker-compose.yml`.

### Services

The Docker Compose setup includes these services:

- **db**: PostgreSQL database
  - Port: 5432
  - Username: jobuser
  - Database: jobsdb
  - Password: jobuser_password

- **test**: Simple test server
  - Port: 8089
  - Built with: Python, FastAPI, Uvicorn

- **admin**: Admin dashboard
  - Port: 8081
  - Built with: Python, FastAPI, Uvicorn

### Volumes

The Docker Compose setup uses these volumes:

- **postgres_data**: Persists PostgreSQL data

## Known Issues and Troubleshooting

### Port Conflicts

If you encounter port conflicts:

```bash
# Check which ports are in use
netstat -tulpn | grep 8089
netstat -tulpn | grep 8081

# Stop specific services
./scripts/manage_services.sh stop test   # Stops the test server
```

### Health Checks

The Docker Compose setup includes health checks for all services. If a service fails its health check:

```bash
# Check the logs
./scripts/manage_services.sh logs <service>

# Restart the service
./scripts/manage_services.sh restart <service>
```

## Advanced Usage

### Customizing the Configuration

1. Edit the `config/config.json` file to modify the scraper configuration
2. Restart the admin service:

```bash
./scripts/manage_services.sh restart admin
```

### Using a Different Docker Compose File

You can use alternative Docker Compose configurations:

```bash
docker-compose -f docker/docker-compose.minimal.yml up -d
```

### Creating a Database Backup

```bash
docker exec -t job_db pg_dump -U jobuser jobsdb > backups/jobsdb_backup_$(date +%Y%m%d_%H%M%S).sql
```

## Additional Resources

- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [FastAPI Documentation](https://fastapi.tiangolo.com/)
- [Docker Compose Documentation](https://docs.docker.com/compose/) 