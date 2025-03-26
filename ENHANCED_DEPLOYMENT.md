# Enhanced Job Scraper Deployment Guide

This guide explains how to deploy the complete Job Scraper application with SSL support and multiple domains.

## Prerequisites

- Ubuntu 22.04 or later server
- Domain name pointing to your server's IP address
- Root access to the server

## Quick Start

1. Upload the enhanced deployment script:
   ```bash
   scp deploy_full_app.sh root@your-server-ip:/root/
   ```

2. Connect to your server:
   ```bash
   ssh root@your-server-ip
   ```

3. Run the full deployment script:
   ```bash
   cd /root
   chmod +x deploy_full_app.sh
   ./deploy_full_app.sh
   ```

4. Access your application at:
   - Main application: https://upgrade4u.online
   - Superset dashboard: https://superset.upgrade4u.online

## Detailed Steps

### 1. Replace Test Application with Full Application

The deployment script will:

1. Create necessary directory structure for the application
2. Clone the full application code from the repository
3. Set up Python virtual environment and dependencies
4. Create application configuration files
5. Set up appropriate permissions
6. Create and start a systemd service

### 2. Configure Nginx for Multiple Domains

The script configures Nginx to:

1. Serve the main application at upgrade4u.online
2. Serve Superset at superset.upgrade4u.online
3. Set up proper proxy configuration for both domains
4. Add security headers and optimal performance settings

### 3. Set Up SSL with Let's Encrypt

SSL will be set up for all domains:

1. Verify DNS records are correctly pointing to the server
2. Obtain SSL certificates from Let's Encrypt
3. Configure Nginx to use the certificates
4. Set up automatic renewal

### 4. Fix Deployment Scripts

The deployment also improves the existing scripts:

1. Fix issues with unbound variables in setup.sh
2. Add better error handling
3. Provide more detailed error messages
4. Create backups before uninstallation

## Maintenance and Troubleshooting

### Checking Status

Check the status of all services:

```bash
systemctl status nginx
systemctl status jobscraper
```

### Viewing Logs

Application logs:
```bash
tail -f /opt/jobscraper/logs/application.log
tail -f /opt/jobscraper/logs/access.log
tail -f /opt/jobscraper/logs/error.log
```

Nginx logs:
```bash
tail -f /var/log/nginx/jobscraper_access.log
tail -f /var/log/nginx/jobscraper_error.log
tail -f /var/log/nginx/superset_access.log
tail -f /var/log/nginx/superset_error.log
```

### Restarting Services

If you need to restart services:

```bash
systemctl restart nginx
systemctl restart jobscraper
```

### SSL Certificate Renewal

SSL certificates from Let's Encrypt automatically renew if Certbot is set up correctly. To manually renew:

```bash
certbot renew
```

## Security Considerations

The deployment includes several security enhancements:

1. HTTPS for all domains with strong SSL configuration
2. Secure application configuration with randomly generated secret keys
3. Proper permission settings for application files
4. Security headers in Nginx
5. Application runs as non-root user

## Additional Configuration

### Adding New Domains

To add a new domain:

1. Create a new Nginx configuration file in `/etc/nginx/sites-available/`
2. Link it to `/etc/nginx/sites-enabled/`
3. Obtain SSL certificate: `certbot --nginx -d new-domain.com`
4. Reload Nginx: `systemctl reload nginx`

### Updating the Application

To update the application:

1. Pull the latest code from the repository
2. Copy it to the application directory
3. Restart the application: `systemctl restart jobscraper`

## Backup and Recovery

### Creating a Backup

```bash
backup_dir="/opt/backups/jobscraper_$(date +%Y%m%d)"
mkdir -p "$backup_dir"
cp -r /opt/jobscraper "$backup_dir/"
pg_dump -U postgres jobsdb > "$backup_dir/jobsdb_backup.sql"
```

### Restoring from Backup

```bash
systemctl stop jobscraper
cp -r /opt/backups/jobscraper_YYYYMMDD/* /opt/jobscraper/
psql -U postgres jobsdb < /opt/backups/jobscraper_YYYYMMDD/jobsdb_backup.sql
systemctl start jobscraper
``` 