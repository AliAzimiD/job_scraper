#!/bin/bash
# Get script directory
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
set -e

echo "=== Job Scraper Minimal Setup ==="
echo "This script installs a minimal setup with just the database and PgAdmin."

# Run cleanup first
echo "=== Cleaning up previous installations ==="
yes | ./cleanup.sh

# Create a very simple docker-compose file
echo "=== Creating minimal docker-compose file ==="
cat > docker-compose.minimal.yml << EOL
version: "3.9"

services:
  db:
    image: postgres:15-alpine
    container_name: job_db
    environment:
      POSTGRES_USER: jobuser
      POSTGRES_DB: jobsdb
      POSTGRES_PASSWORD: jobuser_password
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./migrations:/docker-entrypoint-migrations
      - ./init-db:/docker-entrypoint-initdb.d
    ports:
      - "5432:5432"

  pgadmin:
    image: dpage/pgadmin4:latest
    container_name: job_pgadmin
    environment:
      PGADMIN_DEFAULT_EMAIL: admin@example.com
      PGADMIN_DEFAULT_PASSWORD: admin_password
    volumes:
      - pgadmin_data:/var/lib/pgadmin
    ports:
      - "5050:80"
    depends_on:
      - db

volumes:
  postgres_data:
  pgadmin_data:
EOL

echo "=== Starting database ==="
docker-compose -f docker-compose.minimal.yml up -d

echo "=== Waiting for database to be ready ==="
sleep 10

# Run migrations if they exist
echo "=== Applying migrations ==="
for file in migrations/*.sql; do
  if [ -f "$file" ]; then
    echo "Running migration: $file"
    docker exec -i job_db psql -U jobuser -d jobsdb < "$file" || echo "Warning: Error with $file"
  fi
done

echo "=== Setup Complete ==="
echo "PgAdmin: http://localhost:5050"
echo "  - Email: admin@example.com"
echo "  - Password: admin_password"
echo ""
echo "Database:"
echo "  - Host: localhost"
echo "  - Port: 5432"
echo "  - DB: jobsdb"
echo "  - User: jobuser"
echo "  - Password: jobuser_password" 