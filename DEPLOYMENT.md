# Job Scraper Deployment Guide

This guide explains how to deploy the Job Scraper application to a VPS using the improved deployment workflow.

## Quick Start

1. Configure your settings in `deploy.conf`:
   ```bash
   # Update with your server details
   vim deploy.conf
   ```

2. Run the deployment:
   ```bash
   ./deploy.sh
   ```

3. Access your application at the specified domain when deployment completes.

## Improved Workflow

The deployment system provides an automated workflow that:

1. Tests the deployment locally using Docker before deploying to your VPS
2. Makes deployment and configuration consistent and repeatable
3. Provides better error handling and logging
4. Allows clean uninstallation and reinstallation when needed

## Configuration Options

Edit `deploy.conf` to configure your deployment:

```bash
# Server settings
SERVER_USER="your-username"     # Your SSH username on the VPS
SERVER_HOST="your-server-ip"    # Your VPS IP or hostname
REMOTE_PATH="/path/on/server"   # Path to install on the server

# Repository settings
REPO_URL="https://github.com/yourusername/job-scraper.git"
REPO_BRANCH="main"              # Branch to deploy

# Application config
DOMAIN_NAME="your-domain.com"   # Domain for the app
...                             # Other app settings
```

## Command Line Options

The deployment script offers several options:

```bash
# Show help
./deploy.sh --help

# Test locally using Docker
./deploy.sh --test

# Deploy using a different config file
./deploy.sh --config production.conf

# Clean install (uninstall first if exists)
./deploy.sh --uninstall

# Create a backup before deploying
./deploy.sh --backup

# Skip verification step
./deploy.sh --no-verify
```

## Testing Before Deployment

Always test your deployment locally first:

```bash
./deploy.sh --test
```

This command runs the deployment process in a Docker container, simulating your production environment without affecting your actual VPS.

## Troubleshooting

If deployment fails:

1. Check the log file on the VPS: `setup_YYYYMMDDHHMMSS.log`
2. Use `./deploy.sh --uninstall` to clean up and try again
3. Test locally with `./deploy.sh --test` to identify issues

## Deploying Multiple Environments

You can maintain different configuration files for different environments:

```bash
# Create environment-specific configs
cp deploy.conf deploy.staging.conf
cp deploy.conf deploy.production.conf

# Deploy to staging
./deploy.sh --config deploy.staging.conf

# Deploy to production
./deploy.sh --config deploy.production.conf
```

## Recommended Development Workflow

1. Develop locally on your development branch
2. Test the setup script locally with `./deploy.sh --test`
3. Merge changes to main when ready
4. Deploy to staging server
5. After testing, deploy to production server

Follow this workflow to ensure reliable, consistent deployments. 