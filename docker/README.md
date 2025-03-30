# Job Scraper Docker Configurations

This directory contains alternative Docker Compose configurations for the Job Scraper application.

## Available Configurations

- `docker-compose.dev.yml` - Development configuration with debugging enabled
- `docker-compose.minimal.yml` - Minimal configuration with just the database and PgAdmin
- `docker-compose.updated.yml` - Updated configuration with support for migrations
- `simplified-compose.yml` - Simplified configuration for basic usage

## Usage

To use an alternative configuration:

```bash
# From the project root directory
docker-compose -f docker/docker-compose.dev.yml up -d   # For development
docker-compose -f docker/docker-compose.minimal.yml up -d   # For minimal setup
```

## Main Configuration

The main `docker-compose.yml` file is kept in the project root directory for easy access. 