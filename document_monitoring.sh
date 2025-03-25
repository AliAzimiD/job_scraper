#!/bin/bash
set -e

# Configuration - Use environment variables or prompt for credentials
VPS_IP="${VPS_IP:-23.88.125.23}"
VPS_USER="${VPS_USER:-root}"
VPS_PASSWORD="${VPS_PASSWORD:-}"  # Will prompt if not set
APP_DIR="/opt/job-scraper"
LOCAL_DOCS_DIR="./monitoring_docs"
SSH_OPTS="-o StrictHostKeyChecking=no -o ServerAliveInterval=30 -o ServerAliveCountMax=5 -o ConnectTimeout=30"

# Function to handle errors
handle_error() {
    echo "ERROR: $1"
    echo "The documentation script encountered an error. Please fix the issue and try again."
    exit 1
}

echo "===================================================="
echo "Job Scraper Monitoring Documentation Generator"
echo "===================================================="

# Prompt for VPS password if not set
if [ -z "$VPS_PASSWORD" ]; then
    echo -n "Enter VPS password for ${VPS_USER}@${VPS_IP}: "
    read -s VPS_PASSWORD
    echo ""
    if [ -z "$VPS_PASSWORD" ]; then
        handle_error "Password cannot be empty"
    fi
fi

# Function to run commands on the remote server
run_remote() {
    local max_retries=3
    local retry_count=0
    local cmd="$1"
    
    while [ $retry_count -lt $max_retries ]; do
        echo "  → Running command on remote server (attempt $((retry_count+1))/$max_retries)..."
        if sshpass -p "${VPS_PASSWORD}" ssh ${SSH_OPTS} ${VPS_USER}@${VPS_IP} "$cmd"; then
            return 0
        else
            echo "  → Command failed, retrying in 5 seconds..."
            retry_count=$((retry_count+1))
            sleep 5
        fi
    done
    
    echo "Error executing command on remote server after $max_retries attempts: $cmd"
    return 1
}

# Function to copy files from the remote server
copy_from_remote() {
    local max_retries=3
    local retry_count=0
    local src="$1"
    local dest="$2"
    
    while [ $retry_count -lt $max_retries ]; do
        echo "  → Copying files from remote server (attempt $((retry_count+1))/$max_retries)..."
        if sshpass -p "${VPS_PASSWORD}" scp ${SSH_OPTS} ${VPS_USER}@${VPS_IP}:"$src" "$dest" 2>/dev/null; then
            return 0
        else
            echo "  → File transfer failed, retrying in 5 seconds..."
            retry_count=$((retry_count+1))
            sleep 5
        fi
    done
    
    echo "Warning: Could not copy file(s) $src"
    return 1
}

# Verify required tools are installed
if ! command -v sshpass &> /dev/null; then
    echo "Installing sshpass for non-interactive SSH..."
    sudo apt-get update && sudo apt-get install -y sshpass || handle_error "Failed to install sshpass"
fi

# Create local documentation directory
mkdir -p "${LOCAL_DOCS_DIR}/images"
mkdir -p "${LOCAL_DOCS_DIR}/dashboards"
mkdir -p "${LOCAL_DOCS_DIR}/alerts"

# First, check if Grafana is running
echo "Checking if Grafana is running..."
if ! run_remote "curl -s --connect-timeout 5 --max-time 10 http://localhost:3000/api/health > /dev/null"; then
    echo "WARNING: Grafana is not running or not responding. Some documentation steps may fail."
    echo "Continuing anyway, but some operations may fail..."
fi

# Export dashboards from Grafana
echo "Exporting dashboards from Grafana..."
run_remote "mkdir -p ${APP_DIR}/docs/dashboards"
run_remote "curl -s -H 'Content-Type: application/json' -u admin:admin --connect-timeout 5 --max-time 15 http://localhost:3000/api/search?type=dash-db | jq -c '.[]' > ${APP_DIR}/docs/dashboards/dashboard_list.json || echo '[]' > ${APP_DIR}/docs/dashboards/dashboard_list.json"

# Process the dashboard list to export each one
run_remote "if [ -s ${APP_DIR}/docs/dashboards/dashboard_list.json ]; then
    cat ${APP_DIR}/docs/dashboards/dashboard_list.json | while read -r dashboard; do
        uid=\$(echo \$dashboard | jq -r '.uid')
        title=\$(echo \$dashboard | jq -r '.title')
        echo \"Exporting dashboard: \$title (\$uid)\"
        curl -s -H 'Content-Type: application/json' -u admin:admin http://localhost:3000/api/dashboards/uid/\$uid > ${APP_DIR}/docs/dashboards/\$uid.json || echo \"Failed to export dashboard \$title\"
    done
else
    echo 'No dashboards found to export or dashboard list retrieval failed'
fi"

# Get alert rules
echo "Exporting alert rules..."
run_remote "mkdir -p ${APP_DIR}/docs/alerts"
run_remote "curl -s -H 'Content-Type: application/json' -u admin:admin --connect-timeout 5 --max-time 15 http://localhost:3000/api/alerts | jq > ${APP_DIR}/docs/alerts/alert_rules.json || echo '[]' > ${APP_DIR}/docs/alerts/alert_rules.json"

# Install and use gowitness to capture dashboard screenshots
echo "Capturing dashboard screenshots..."
run_remote "mkdir -p ${APP_DIR}/docs/images"
run_remote "which gowitness >/dev/null 2>&1 || (apt-get update && apt-get install -y golang && go install github.com/sensepost/gowitness@latest)"

# Capture screenshots of dashboards, handle potential errors
echo "Capturing main dashboard..."
run_remote "cd ${APP_DIR}/docs && (~/go/bin/gowitness single http://localhost:3000/d/job-scraper-dashboard --delay 5 --resolution \"1920x1080\" -o images/main-dashboard.png 2>/dev/null || echo 'Warning: Could not capture main dashboard screenshot')"

echo "Capturing CPU usage dashboard..."
run_remote "cd ${APP_DIR}/docs && (~/go/bin/gowitness single http://localhost:3000/d/cpu --delay 5 --resolution \"1920x1080\" -o images/cpu-usage.png 2>/dev/null || echo 'Warning: Could not capture CPU dashboard screenshot')"

echo "Capturing error dashboard..."
run_remote "cd ${APP_DIR}/docs && (~/go/bin/gowitness single http://localhost:3000/d/errors --delay 5 --resolution \"1920x1080\" -o images/errors.png 2>/dev/null || echo 'Warning: Could not capture errors dashboard screenshot')"

echo "Capturing new jobs dashboard..."
run_remote "cd ${APP_DIR}/docs && (~/go/bin/gowitness single http://localhost:3000/d/newjobs --delay 5 --resolution \"1920x1080\" -o images/new-jobs.png 2>/dev/null || echo 'Warning: Could not capture new jobs dashboard screenshot')"

# Copy documentation from remote server to local
echo "Copying documentation files locally..."
run_remote "find ${APP_DIR}/docs/dashboards -type f -name '*.json' | wc -l"
run_remote "find ${APP_DIR}/docs/alerts -type f -name '*.json' | wc -l"
run_remote "find ${APP_DIR}/docs/images -type f -name '*.png' | wc -l"

# Use wildcards for directory contents, not the directories themselves
copy_from_remote "${APP_DIR}/docs/dashboards/*.json" "${LOCAL_DOCS_DIR}/dashboards/"
copy_from_remote "${APP_DIR}/docs/alerts/*.json" "${LOCAL_DOCS_DIR}/alerts/"
copy_from_remote "${APP_DIR}/docs/images/*.png" "${LOCAL_DOCS_DIR}/images/"

# Generate Markdown documentation
echo "Generating markdown documentation..."
cat > "${LOCAL_DOCS_DIR}/DASHBOARD_GUIDE.md" << 'EOF'
# Job Scraper Monitoring Dashboards

This guide provides information about the monitoring dashboards set up for the Job Scraper application.

## Main Dashboard

![Main Dashboard](./images/main-dashboard.png)

The main dashboard provides an overview of all key metrics for the Job Scraper application:

- **Total Jobs**: Shows the total number of jobs in the database
- **New Jobs (24h)**: Displays how many new jobs were collected in the last 24 hours
- **Errors (1h)**: Shows the number of errors encountered in the last hour
- **Scraper Status**: Indicates if the scraper is currently running

### Key Panels

- **Jobs Collected (24h)**: Time series graph showing total and new jobs over time
- **Scrape Performance**: Tracks API request duration and scrape times
- **Resource Usage**: Monitors CPU and memory utilization

## CPU Usage Dashboard

![CPU Dashboard](./images/cpu-usage.png)

The CPU usage dashboard tracks the application's CPU utilization over time and triggers alerts when usage is consistently high.

**Alert Condition**: CPU usage > 80% for 5+ minutes

## Error Tracking Dashboard

![Errors Dashboard](./images/errors.png)

This dashboard monitors various error types encountered during scraping:

- API request failures
- Database connection issues
- Parsing errors

**Alert Condition**: More than 5 errors in 5 minutes

## New Jobs Dashboard

![New Jobs Dashboard](./images/new-jobs.png)

Tracks the rate of new job collection, which is vital for ensuring the scraper is working correctly.

**Alert Condition**: No new jobs collected for 24 hours

## How to Use These Dashboards

1. **Regular Monitoring**: Check the main dashboard daily to ensure the application is operating normally
2. **Troubleshooting**: Use the specific dashboards when investigating issues
3. **Alert Investigation**: When alerts trigger, use these dashboards to find the root cause

## Customizing Dashboards

To customize these dashboards:

1. Log in to Grafana at http://YOUR_SERVER_IP:3000
2. Navigate to the dashboard you want to modify
3. Click the settings icon (gear) in the top right
4. Make desired changes and click "Save"

## Exporting and Importing Dashboards

Export dashboards for backup or sharing:

1. Navigate to the dashboard
2. Click the share icon
3. Select the "Export" tab
4. Click "Save to file"

Import dashboards:

1. Click the "+" icon in the side menu
2. Select "Import"
3. Upload the JSON file or paste dashboard JSON
EOF

# Generate alert documentation
cat > "${LOCAL_DOCS_DIR}/ALERTS_GUIDE.md" << 'EOF'
# Job Scraper Alert Configuration Guide

This document explains the alerts set up for the Job Scraper application.

## Available Alerts

### High CPU Usage Alert

Triggers when the application's CPU usage exceeds 80% for more than 5 minutes.

**Use case**: Detecting performance issues or runaway processes that might affect scraping efficiency.

**Response**: Check for resource-intensive operations or consider scaling up server resources.

### Scraper Errors Alert

Triggers when more than 5 errors occur within a 5-minute period.

**Use case**: Detecting API issues, parsing problems, or other operational failures.

**Response**: Check the application logs for error details and investigate potential API changes or network issues.

### No New Jobs Alert

Triggers when no new jobs have been collected for 24 hours.

**Use case**: Detecting when the scraper has stopped collecting jobs, which could indicate a major failure.

**Response**: Verify the scraper is running, check for API changes, and review any errors in the logs.

## Alert Notification Channels

The following notification channels are configured:

- **Slack**: Sends alerts to a designated Slack channel
- **Email**: Sends alert notifications via email

### Configuring Notification Channels

To update notification settings:

1. Log in to Grafana at http://YOUR_SERVER_IP:3000
2. Go to Alerting → Notification channels
3. Edit the existing channels with your specific details

#### Slack Configuration

Required fields:
- Webhook URL: Your Slack incoming webhook URL
- Recipient: The channel where alerts should be sent (e.g., #alerts)

#### Email Configuration

Required fields:
- Email addresses: Comma-separated list of email recipients

## Alert Severity Levels

Alerts are categorized by severity:

- **Critical**: Service outages, database failures, no new jobs
- **Warning**: High error rates, resource utilization
- **Info**: Non-urgent conditions like job count changes

## Testing Alerts

To test if alerts are working correctly:

1. Log in to Grafana
2. Navigate to the dashboard with the alert
3. Edit the panel with the alert
4. Go to the Alert tab
5. Click "Test Rule"

## Silencing Alerts

To temporarily silence an alert:

1. When an alert is fired, click on the alert
2. Click "Silence"
3. Set the duration and reason for silencing

## Alert History

View the history of alert state changes:

1. In Grafana, go to Alerting → Alert Rules
2. Click on a specific alert
3. View the "State history" tab
EOF

# Generate a summary document with links to documentation
cat > "${LOCAL_DOCS_DIR}/README.md" << EOF
# Job Scraper Monitoring Documentation

Generated on: $(date)

## Contents

- [Dashboard Guide](./DASHBOARD_GUIDE.md)
- [Alerts Guide](./ALERTS_GUIDE.md)

## Quick Links

- Application: http://${VPS_IP}:5000
- Grafana: http://${VPS_IP}:3000
- Prometheus: http://${VPS_IP}:9090
EOF

echo "===================================================="
echo "Documentation Generation Complete!"
echo "===================================================="
echo
echo "Documentation has been generated in: ${LOCAL_DOCS_DIR}"
echo
echo "Files created:"
echo "  - README.md: Overview of monitoring documentation"
echo "  - DASHBOARD_GUIDE.md: Guide to using the monitoring dashboards"
echo "  - ALERTS_GUIDE.md: Guide to the alert configuration"
echo "  - images/: Screenshots of the dashboards (if available)"
echo "  - dashboards/: Exported dashboard definitions"
echo "  - alerts/: Alert rules configuration"
echo
echo "You can edit these files to add more detailed information"
echo "specific to your implementation."
echo "====================================================" 