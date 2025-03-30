#!/bin/bash
set -e

# This script runs during PostgreSQL initialization to apply schema migrations

echo "Checking if schema upgrade is needed..."

# Get PostgreSQL connection details
PGDB=${POSTGRES_DB:-jobsdb}
PGUSER=${POSTGRES_USER:-jobuser}

# Check if schema_version table exists
SCHEMA_EXISTS=$(psql -U "$PGUSER" -d "$PGDB" -t -c "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'schema_version')")

if [[ $SCHEMA_EXISTS == *"t"* ]]; then
    echo "Schema version table exists, skipping initial migration"
    exit 0
fi

echo "Performing initial schema migration..."

# Apply migration scripts in order if they exist
for MIGRATION_FILE in /docker-entrypoint-migrations/*.sql; do
    if [ -f "$MIGRATION_FILE" ]; then
        echo "Applying migration: $MIGRATION_FILE"
        psql -U "$PGUSER" -d "$PGDB" -f "$MIGRATION_FILE" || echo "Warning: Error applying $MIGRATION_FILE"
    fi
done

# Create schema_version table
psql -U "$PGUSER" -d "$PGDB" -c "
CREATE TABLE IF NOT EXISTS public.schema_version (
    id SERIAL PRIMARY KEY,
    version INTEGER NOT NULL,
    description TEXT,
    applied_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Insert initial version record
INSERT INTO public.schema_version (version, description)
VALUES (2, 'Initial normalized schema migration')
"

echo "Schema initialization complete!"
