#!/bin/bash
# Get script directory
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
set -e

# This script starts only the database container

echo "Starting database container..."

# Ensure docker-compose is using the updated file
if [ ! -f "docker-compose.yml" ] || ! grep -q "migrations:/docker-entrypoint-migrations" docker-compose.yml; then
    echo "Copying updated docker-compose file..."
    cp migrations/docker-compose.updated.yml docker-compose.yml
fi

# Stop any existing container
if docker ps -a | grep -q "job_db"; then
    echo "Stopping existing database container..."
    docker-compose stop db
    docker-compose rm -f db
fi

# Start just the database
echo "Starting fresh database container..."
docker-compose up -d --force-recreate db

# Wait for it to be ready
echo -n "Waiting for database to be ready."
for i in {1..30}; do
    if docker exec job_db pg_isready -U jobuser -d jobsdb > /dev/null 2>&1; then
        echo ""
        echo "Database is ready!"
        break
    fi
    echo -n "."
    sleep 2
    if [ $i -eq 30 ]; then
        echo ""
        echo "WARNING: Database did not become ready in time."
    fi
done

echo "Database container is running. You can now run migrations or connect to it."
echo "To run migrations: ./run-migrations.sh"
echo "To connect with psql: docker-compose exec db psql -U jobuser -d jobsdb" 