#!/bin/bash
set -e

# This script runs only the database migrations

echo "Starting database migrations..."

# Ensure docker-compose is using the updated file
if [ ! -f "docker-compose.yml" ] || ! grep -q "migrations:/docker-entrypoint-migrations" docker-compose.yml; then
    echo "Copying updated docker-compose file..."
    cp migrations/docker-compose.updated.yml docker-compose.yml
fi

# Run the migrations
echo "Running migrations service..."
docker-compose --profile migrations up --force-recreate migrator

echo "Migrations completed." 