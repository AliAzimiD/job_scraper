# Job Scraper Deployment

This directory contains everything needed to deploy the Job Scraper application using Docker and Docker Compose.

## Structure

- `app/`: The Flask application
- `nginx/`: Nginx configuration files
- `scripts/`: Deployment scripts
- `docker-compose.yml`: Docker Compose configuration

## Quick Start

1. Make sure you're in the project root directory:

```bash
cd job-scraper-deploy
```

2. Run the deployment script:

```bash
./scripts/deploy.sh
```

This will:
- Create necessary directories on the server
- Upload all files to the server
- Install Docker and Docker Compose if not already installed
- Deploy the application with Docker Compose
- Configure SSL certificates (requires a valid domain pointing to the server)

## Manual Deployment

If you prefer to deploy manually:

1. Create necessary directories on the server:

```bash
ssh root@23.88.125.23 "mkdir -p /opt/jobscraper/{app,nginx,data/logs,data/static,data/certbot/conf,data/certbot/www}"
```

2. Create a tar archive of all files and upload it:

```bash
tar -czf deploy.tar.gz .
scp deploy.tar.gz root@23.88.125.23:/opt/jobscraper/
ssh root@23.88.125.23 "cd /opt/jobscraper && tar -xzf deploy.tar.gz && rm deploy.tar.gz"
```

3. Deploy with Docker Compose:

```bash
ssh root@23.88.125.23 "cd /opt/jobscraper && docker-compose up -d"
```

## SSL Configuration

SSL certificates are obtained from Let's Encrypt using the Certbot container. The process is automated in the deployment script, but you can also configure it manually:

```bash
ssh root@23.88.125.23 "cd /opt/jobscraper && docker run --rm -v ./data/certbot/conf:/etc/letsencrypt -v ./data/certbot/www:/var/www/certbot certbot/certbot certonly --webroot --webroot-path=/var/www/certbot --email your-email@example.com --agree-tos --no-eff-email -d your-domain.com"
```

After obtaining the certificates, enable the SSL configuration:

```bash
ssh root@23.88.125.23 "cd /opt/jobscraper && cp nginx/conf/ssl.conf.template nginx/conf/default.conf && docker-compose exec nginx nginx -s reload"
```

## Accessing the Application

Once deployed, the application can be accessed at:

- HTTP: http://upgrade4u.online
- HTTPS (after SSL setup): https://upgrade4u.online

## Troubleshooting

If you encounter issues:

1. Check the container logs:

```bash
ssh root@23.88.125.23 "cd /opt/jobscraper && docker-compose logs"
```

2. Check the container status:

```bash
ssh root@23.88.125.23 "cd /opt/jobscraper && docker-compose ps"
```

3. Restart the containers:

```bash
ssh root@23.88.125.23 "cd /opt/jobscraper && docker-compose restart"
``` 