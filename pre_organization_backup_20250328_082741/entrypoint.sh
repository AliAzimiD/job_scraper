#!/bin/bash
# entrypoint.sh
# This script sets up the container environment, starts auxiliary services (health check and cron),
# and finally launches the scraper application with proper signal handling and privilege dropping.

# Exit immediately if a command exits with a non-zero status.
set -e

##############################
# Function Definitions
##############################

# Log a message with a timestamp.
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S") - $1"
}

# Cleanup function to gracefully shut down services on SIGTERM/SIGINT.
cleanup() {
    log "Received shutdown signal. Initiating cleanup..."
    if [ -n "$HEALTH_PID" ]; then
        log "Stopping health check service (PID=$HEALTH_PID)..."
        kill -TERM "$HEALTH_PID" 2>/dev/null || true
    fi
    if [ "$ENABLE_CRON" = "true" ]; then
        log "Stopping cron service..."
        service cron stop || true
    fi
    log "Cleanup complete. Exiting."
    exit 0
}

# Setup the log directory and fix permissions.
setup_logs() {
    log "Creating log directory and setting permissions..."
    mkdir -p /app/job_data/logs
    chmod -R 755 /app/job_data
    # Ensure ownership for logs is correct.
    chown -R scraper:scraper /app/job_data
    find /app/job_data/logs -type f -name "*.log" -exec chown scraper:scraper {} \;
    find /app/job_data/logs -type f -name "*.log" -exec chmod 644 {} \;

    # Ensure cron.log exists with proper permissions.
    touch /app/job_data/logs/cron.log
    chown scraper:scraper /app/job_data/logs/cron.log
    chmod 644 /app/job_data/logs/cron.log
}

# Start the health check service in the background.
start_health() {
    log "Starting health check Flask service on port 8081..."
    # Start the health service in the background.
    python /app/health/app.py &
    HEALTH_PID=$!
    log "Health check service started with PID=$HEALTH_PID"

    # Wait until the health service responds.
    for i in {1..10}; do
        if curl -s http://localhost:8081/health > /dev/null; then
            log "Health service is up and running!"
            return 0
        fi
        if [ "$i" -eq 10 ]; then
            log "ERROR: Health service failed to start after 10 attempts!"
            exit 1
        fi
        log "Health service not ready yet... ($i/10)"
        sleep 1
    done
}

# Start cron service (runs as root) if enabled.
start_cron() {
    if [ "$ENABLE_CRON" = "true" ]; then
        log "Starting cron service..."
        # Start cron as root so that /var/run/crond.pid can be written.
        service cron start || { log "Failed to start cron service"; exit 1; }
        log "Cron service started successfully."

        # Verify that cron is running.
        if ! service cron status > /dev/null; then
            log "ERROR: Cron service is not running!"
            exit 1
        fi
        log "Cron service verified as running."
    fi
}

# Run the scraper job.
run_scraper_job() {
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="/app/job_data/logs/scraper_${TIMESTAMP}.log"
    touch "$LOG_FILE"
    chown scraper:scraper "$LOG_FILE"

    log "Running initial scraper job; logging output to $LOG_FILE"

    # Use gosu to drop privileges to the 'scraper' user.
    if ! gosu scraper bash -c "cd /app && python /app/main.py > $LOG_FILE 2>&1"; then
        log "ERROR: Initial scraper job failed. Showing last 20 lines of log:"
        tail -n 20 "$LOG_FILE" || echo "No log file found at $LOG_FILE"
        exit 1
    fi

    log "Initial scraper job completed successfully."
}

##############################
# Main Script Execution
##############################

# Set up trap to catch SIGTERM and SIGINT signals.
trap cleanup SIGTERM SIGINT

# Validate required environment variables.
if [ -z "$SCRAPER_ENV" ]; then
    log "ERROR: SCRAPER_ENV environment variable is not set!"
    exit 1
fi

log "Starting job scraper in $SCRAPER_ENV environment..."

# Setup logs directory and permissions.
setup_logs

# Start the health check service.
start_health

# Optionally start the cron service.
start_cron

# If RUN_ON_START is true, run the scraper immediately.
if [ "$RUN_ON_START" = "true" ]; then
    run_scraper_job
fi

# If cron is enabled, keep the container running.
if [ "$ENABLE_CRON" = "true" ]; then
    log "Container will remain running to support cron jobs."
    exec tail -f /app/job_data/logs/cron.log
else
    log "ENABLE_CRON is false; container will exit after scraper job completes."
    exit 0
fi
