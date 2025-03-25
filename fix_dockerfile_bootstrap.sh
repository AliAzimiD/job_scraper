#!/bin/bash

cat > fixed_dockerfile_with_bootstrap << 'EOF'
FROM python:3.11-slim

WORKDIR /app

# Add retry and timeout functionality for apt-get
RUN echo 'Acquire::Retries "5";' > /etc/apt/apt.conf.d/80retries && \
    echo 'Acquire::http::Timeout "120";' > /etc/apt/apt.conf.d/99timeout && \
    echo 'Acquire::https::Timeout "120";' >> /etc/apt/apt.conf.d/99timeout

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    curl \
    git \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Set pip configuration for reliability
ENV PIP_DEFAULT_TIMEOUT=100 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1 \
    SQLALCHEMY_SILENCE_UBER_WARNING=1

# Copy requirements first to leverage Docker cache
COPY requirements.txt .

# Install Python dependencies with flask-bootstrap
RUN pip install --retries 5 -r requirements.txt && \
    pip install flask-bootstrap

# Create scripts directory to prevent error
RUN mkdir -p /app/scripts && touch /app/scripts/placeholder.sh && chmod +x /app/scripts/placeholder.sh

# Copy the application code
COPY . .

# Set Python path
ENV PYTHONPATH=/app

# Expose port
EXPOSE 5000

# Start the application
CMD ["python", "-m", "src.web_app"]
EOF

# Copy to server
export VPS_PASS="jy6adu06wxefmvsi1kzo"
sshpass -p "$VPS_PASS" scp -o StrictHostKeyChecking=no fixed_dockerfile_with_bootstrap root@23.88.125.23:/opt/job-scraper/docker/Dockerfile

# Rebuild and restart the container
sshpass -p "$VPS_PASS" ssh -o StrictHostKeyChecking=no root@23.88.125.23 "cd /opt/job-scraper && docker-compose build web && docker-compose up -d web" 