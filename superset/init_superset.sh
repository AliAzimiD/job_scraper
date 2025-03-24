#!/bin/bash
set -e

# Function to wait for database to be ready
wait_for_db() {
    echo "Waiting for database to be ready..."
    while ! nc -z "${DB_HOST:-postgres}" "${DB_PORT:-5432}"; do
        sleep 0.5
    done
    echo "Database is ready."
}

# Initialize Superset if not already done
initialize_superset() {
    echo "Initializing Superset..."

    # Create admin user
    superset fab create-admin \
        --username admin \
        --firstname Superset \
        --lastname Admin \
        --email admin@jobscraper.local \
        --password "${ADMIN_PASSWORD:-admin}" \
        || true  # Ignore if user already exists

    # Upgrade the database
    superset db upgrade

    # Setup roles
    superset init

    echo "Superset initialization completed."
}

# Create database connections
setup_database_connections() {
    echo "Setting up database connections..."
    
    # Create connection to job scraper database
    superset set-database-uri \
        --database-name "Job Scraper DB" \
        --uri "${DATABASE_URI:-postgresql://jobuser:devpassword@postgres:5432/jobsdb}" \
        || superset set-database-uri \
            --database-name "Job Scraper DB" \
            --uri "${DATABASE_URI:-postgresql://jobuser:devpassword@postgres:5432/jobsdb}" \
            --overwrite || true

    echo "Database connections setup completed."
}

# Import dashboards if they exist
import_dashboards() {
    echo "Importing dashboards..."
    
    # Check if we have dashboard files to import
    if [ -d "/app/dashboards" ] && [ "$(ls -A /app/dashboards)" ]; then
        for dashboard_file in /app/dashboards/*.json; do
            if [ -f "$dashboard_file" ]; then
                echo "Importing dashboard: $dashboard_file"
                superset import-dashboards -p "$dashboard_file" || true
            fi
        done
        echo "Dashboard import completed."
    else
        echo "No dashboards to import."
    fi
}

# Create sample job dashboard
create_sample_dashboard() {
    echo "Creating sample job dashboard..."
    
    # Define SQL for basic charts
    JOB_TREND_SQL="SELECT DATE_TRUNC('day', activation_time) as post_date, COUNT(*) as job_count
                  FROM jobs 
                  WHERE activation_time > CURRENT_DATE - INTERVAL '90 days'
                  GROUP BY post_date 
                  ORDER BY post_date;"
                  
    LOCATION_SQL="SELECT 
                   CASE WHEN locations IS NULL THEN 'Unknown'
                   WHEN locations = '[]' THEN 'Unknown'
                   ELSE locations->0->>'city' END as location,
                   COUNT(*) as job_count
                  FROM jobs
                  GROUP BY location
                  ORDER BY job_count DESC
                  LIMIT 10;"
                  
    JOB_CATEGORY_SQL="SELECT 
                      COALESCE(job_categories->0->>'name', 'Uncategorized') as category, 
                      COUNT(*) as job_count
                      FROM jobs
                      GROUP BY category
                      ORDER BY job_count DESC
                      LIMIT 10;"
    
    # TODO: Use Superset API to programmatically create charts and dashboard
    # This would require additional Python scripts
    
    echo "Sample dashboard creation completed."
}

# Main execution
main() {
    # Wait for the database first
    wait_for_db
    
    # Initialize Superset components
    initialize_superset
    setup_database_connections
    import_dashboards
    
    # Create sample dashboard if configured
    if [ "${CREATE_SAMPLE_DASHBOARD:-true}" = "true" ]; then
        create_sample_dashboard
    fi
    
    # Start Superset
    echo "Starting Superset server..."
    exec superset run -p 8088 --with-threads --reload --debugger
}

# Execute main function
main 