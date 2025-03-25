# Job Scraper Production Setup Guide

This document provides detailed instructions for deploying the Job Scraper application in a production environment.

## System Requirements

### Hardware Recommendations
- **CPU**: 2+ cores recommended (4+ for heavy workloads)
- **RAM**: 4GB minimum, 8GB+ recommended
- **Storage**: 20GB+ SSD (depending on job data volume)
- **Network**: Stable internet connection with minimum 10Mbps

### Software Requirements
- **Operating System**: Ubuntu 20.04+ LTS
- **Docker**: 20.10+ and Docker Compose v2+
- **Database**: PostgreSQL 14+ (built-in or external)
- **Web Server**: Nginx (as reverse proxy)
- **SSL**: Let's Encrypt certificates

## Deployment Options

The job scraper application can be deployed in two ways:

1. **Docker-based deployment** (recommended): Uses the `deploy_vps.sh` script to automatically set up all components in Docker containers.
2. **Native deployment**: Manual setup directly on the host system.

## Docker-based Deployment

### Step 1: Prepare the server

1. Update system packages:
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

2. Install basic dependencies:
   ```bash
   sudo apt install -y git curl wget
   ```

### Step 2: Clone the repository

```bash
git clone https://github.com/yourusername/job-scraper.git /tmp/job-scraper
cd /tmp/job-scraper
```

### Step 3: Run the deployment script

```bash
sudo bash deploy_vps.sh
```

The script will:
- Install Docker and Docker Compose
- Create necessary directories
- Configure systemd services for automatic startup
- Set up secure credentials
- Configure Nginx as a reverse proxy
- Set up scheduled job runs between 6 AM and 11 PM
- Configure automatic backups

### Step 4: Configure SSL (optional but recommended)

```bash
sudo certbot --nginx -d your-domain.com
```

## Native Deployment

If you prefer to deploy without Docker, follow these steps:

### Step 1: Install dependencies

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git python3-pip python3-venv postgresql nginx certbot python3-certbot-nginx
```

### Step 2: Clone the repository

```bash
sudo mkdir -p /opt/job-scraper
sudo git clone https://github.com/yourusername/job-scraper.git /opt/job-scraper
cd /opt/job-scraper
```

### Step 3: Set up Python environment

```bash
sudo python3 -m venv /opt/job-scraper/venv
sudo /opt/job-scraper/venv/bin/pip install -U pip
sudo /opt/job-scraper/venv/bin/pip install -r requirements.txt
```

### Step 4: Configure PostgreSQL

```bash
sudo -u postgres psql -c "CREATE USER jobuser WITH PASSWORD 'secure_password';"
sudo -u postgres psql -c "CREATE DATABASE jobsdb OWNER jobuser;"
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE jobsdb TO jobuser;"
```

### Step 5: Set up systemd services

Create the service file:

```bash
sudo nano /etc/systemd/system/job-scraper.service
```

Add the following content:

```ini
[Unit]
Description=Job Scraper Service
After=network.target postgresql.service
Wants=postgresql.service

[Service]
User=www-data
Group=www-data
WorkingDirectory=/opt/job-scraper
Environment="PATH=/opt/job-scraper/venv/bin"
ExecStart=/opt/job-scraper/venv/bin/python -m src.web_app
Restart=on-failure
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
```

Create the timer for scheduled scraping:

```bash
sudo nano /etc/systemd/system/job-scraper-run.service
```

```ini
[Unit]
Description=Run Job Scraper
After=job-scraper.service

[Service]
User=www-data
Group=www-data
WorkingDirectory=/opt/job-scraper
Environment="PATH=/opt/job-scraper/venv/bin"
ExecStart=/opt/job-scraper/venv/bin/python -m src.main

[Install]
WantedBy=multi-user.target
```

```bash
sudo nano /etc/systemd/system/job-scraper-run.timer
```

```ini
[Unit]
Description=Run job scraper hourly between 6 AM and 11 PM
After=job-scraper.service

[Timer]
OnCalendar=*-*-* 06..23:00:00
AccuracySec=1min
Persistent=true

[Install]
WantedBy=timers.target
```

Enable the services:

```bash
sudo systemctl daemon-reload
sudo systemctl enable job-scraper.service
sudo systemctl enable job-scraper-run.timer
sudo systemctl start job-scraper.service
sudo systemctl start job-scraper-run.timer
```

### Step 6: Configure Nginx

```bash
sudo nano /etc/nginx/sites-available/job-scraper
```

Add:

```nginx
server {
    listen 80;
    server_name your-domain.com;

    location / {
        proxy_pass http://localhost:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /superset/ {
        proxy_pass http://localhost:8088/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

Enable and restart:

```bash
sudo ln -s /etc/nginx/sites-available/job-scraper /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo systemctl restart nginx
```

## Configuration Options

### Environment Variables

The application can be configured using environment variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `POSTGRES_HOST` | Database host | `localhost` |
| `POSTGRES_PORT` | Database port | `5432` |
| `POSTGRES_DB` | Database name | `jobsdb` |
| `POSTGRES_USER` | Database user | `jobuser` |
| `POSTGRES_PASSWORD` | Database password | `devpassword` |
| `FLASK_SECRET_KEY` | Secret key for Flask | Random generated |
| `API_USERNAME` | Username for API access | `api_user` |
| `API_PASSWORD` | Password for API access | Random generated |
| `LOG_LEVEL` | Logging level | `INFO` |
| `SCRAPER_CONFIG_PATH` | Path to scraper config | `config/api_config.yaml` |

### Configuration Files

- **config/app_config.yaml**: Application settings
- **config/api_config.yaml**: API and scraper settings

## Backup and Restore

### Automatic Backups

In the Docker setup, backups are scheduled daily at 5:00 AM using systemd timers. Backups are stored in `/var/backups/job-scraper`.

### Manual Backup

```bash
cd /opt/job-scraper
sudo bash backup_current_db.sh
```

### Restore from Backup

```bash
cd /opt/job-scraper
sudo bash import_backup.sh /path/to/backup.dump
```

## Monitoring

### Health Checks

The application provides health check endpoints:

- Web application: `http://your-domain.com/api/health`
- Superset: `http://your-domain.com/superset/health`

### Logs

Logs are stored in:

- Docker setup: `/var/log/job-scraper/`
- Native setup: `/var/log/job-scraper/` and systemd journal

View logs:

```bash
# Application logs
sudo tail -f /var/log/job-scraper/app.log

# Scraper logs
sudo tail -f /var/log/job-scraper/scraper.log

# Systemd service logs
sudo journalctl -u job-scraper.service -f
```

### Prometheus and Grafana Monitoring

The Job Scraper application comes with a comprehensive monitoring stack based on Prometheus and Grafana.

#### Starting the Monitoring Stack

```bash
# Start the monitoring services
./start_monitoring.sh
```

This script will:
- Set up Prometheus for metrics collection
- Configure Grafana for visualization
- Add exporters for PostgreSQL, Redis, and system metrics
- Configure pre-built dashboards

#### Accessing Monitoring Dashboards

- Prometheus: `http://your-domain.com:9090`
- Grafana: `http://your-domain.com:3000` (default credentials: admin/admin)

#### Available Metrics

The Job Scraper application exposes metrics via a `/metrics` endpoint including:
- Jobs collected and processing stats
- API request performance
- Error rates and types
- System resource usage

#### Custom Dashboards

The monitoring setup includes a pre-configured dashboard for the Job Scraper application that provides:
- Real-time visibility of job collection rates
- Error and performance monitoring
- Resource usage tracking
- Time-series data for trend analysis

#### Setting Up Alerting

Configure alerts in Grafana:
1. Log in to Grafana
2. Go to Alerting → Notification channels
3. Add channels for email, Slack, or other services
4. Create alert rules based on thresholds

Prometheus alerting is also configured with pre-defined rules in `prometheus/alerts.yml`.

#### Securing the Monitoring Stack

In a production environment, consider:
1. Changing default Grafana credentials
2. Setting up reverse proxy with authentication
3. Restricting access to monitoring ports (9090, 3000) to trusted networks
4. Enabling TLS for secure communications

For detailed information, refer to the [MONITORING.md](MONITORING.md) document.

## Scaling and Performance Tuning

### Database Tuning

Edit PostgreSQL configuration:

```bash
sudo nano /etc/postgresql/14/main/postgresql.conf
```

Recommended settings:

```
shared_buffers = 1GB  # 25% of RAM
work_mem = 50MB       # Depends on concurrent connections
maintenance_work_mem = 256MB
effective_cache_size = 3GB  # 75% of RAM
```

### Application Scaling

For higher loads:

1. Increase worker processes in `docker-compose.yml` or gunicorn settings
2. Use a load balancer for multiple application instances
3. Scale database with read replicas

## Troubleshooting

### Service Won't Start

Check logs:

```bash
sudo journalctl -u job-scraper.service -n 100 --no-pager
```

### Database Connection Issues

Test connection:

```bash
psql -U jobuser -h localhost -d jobsdb -W
```

### API Rate Limiting

If you're experiencing rate limiting from job APIs:

1. Decrease `max_concurrent_requests` in `config/api_config.yaml`
2. Increase `request_interval_ms` in the same file

## Security Best Practices

1. **Run regular updates**:
   ```bash
   sudo apt update && sudo apt upgrade -y
   ```

2. **Use a firewall**:
   ```bash
   sudo ufw allow ssh
   sudo ufw allow http
   sudo ufw allow https
   sudo ufw enable
   ```

3. **Secure PostgreSQL**:
   ```bash
   sudo nano /etc/postgresql/14/main/pg_hba.conf
   ```
   Restrict to local connections only

4. **Set up fail2ban**:
   ```bash
   sudo apt install fail2ban
   sudo systemctl enable fail2ban
   sudo systemctl start fail2ban
   ```

5. **Enable HTTPS with strong ciphers**

## Additional Resources

- [System Administration Guide](https://ubuntu.com/server/docs)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Docker Documentation](https://docs.docker.com/)
- [Nginx Documentation](https://nginx.org/en/docs/)

## Support

For issues and support, please create an issue on the GitHub repository or contact the maintainer. 