#!/bin/bash
echo "Setting up Job Scraper app..."
mkdir -p /opt/jobscraper/final/{app,nginx/conf,data/{logs,static,uploads,certbot/conf,certbot/www}}
echo "server { listen 80; server_name upgrade4u.online; location / { proxy_pass http://web:5000; } }" > /opt/jobscraper/final/nginx/conf/default.conf
cat > /opt/jobscraper/final/docker-compose.yml << EOF
version: "3.8"

services:
  web:
    build:
      context: ./app
    container_name: job-scraper-web
    restart: unless-stopped
    volumes:
      - ./app:/app
      - ./data/logs:/app/logs
      - ./data/static:/app/static
      - ./data/uploads:/app/uploads
    environment:
      - FLASK_APP=app
      - FLASK_ENV=production
      - FLASK_DEBUG=0
      - DATABASE_URL=postgresql://postgres:aliazimid@postgres:5432/jobsdb
      - REDIS_HOST=redis
      - REDIS_PORT=6379
    depends_on:
      - postgres
      - redis
    networks:
      - job-scraper-network

  postgres:
    image: postgres:15-alpine
    container_name: job-scraper-postgres
    restart: unless-stopped
    volumes:
      - postgres-data:/var/lib/postgresql/data
      - ./data/init-db:/docker-entrypoint-initdb.d
    environment:
      - POSTGRES_USER=postgres
      - POSTGRES_PASSWORD=aliazimid
      - POSTGRES_DB=jobsdb
    networks:
      - job-scraper-network

  redis:
    image: redis:7-alpine
    container_name: job-scraper-redis
    restart: unless-stopped
    command: redis-server --appendonly yes
    volumes:
      - redis-data:/data
    networks:
      - job-scraper-network

  nginx:
    image: nginx:1.25-alpine
    container_name: job-scraper-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/conf:/etc/nginx/conf.d
      - ./data/static:/usr/share/nginx/html/static
      - ./data/certbot/conf:/etc/letsencrypt
      - ./data/certbot/www:/var/www/certbot
    depends_on:
      - web
    networks:
      - job-scraper-network

  certbot:
    image: certbot/certbot
    container_name: job-scraper-certbot
    volumes:
      - ./data/certbot/conf:/etc/letsencrypt
      - ./data/certbot/www:/var/www/certbot
    entrypoint: "/bin/sh -c \"trap exit TERM; while :; do certbot renew; sleep 12h & wait $${!}; done;\""

volumes:
  postgres-data:
  redis-data:

networks:
  job-scraper-network:
    driver: bridge
EOF
cd /opt/jobscraper/final && docker-compose down && docker-compose up -d
