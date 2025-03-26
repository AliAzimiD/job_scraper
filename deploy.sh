#!/bin/bash
# Comprehensive Job Scraper Deployment Script

# ===== Color Definitions =====
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ===== Configuration =====
SERVER_HOST="23.88.125.23"
SERVER_USER="root"
DEPLOY_DIR="/opt/jobscraper"
DOMAIN="upgrade4u.online"
EMAIL="aliazimidarmian@gmail.com"

# ===== Logging Functions =====
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# ===== Function to check for dependencies =====
check_dependencies() {
    log "Checking for required dependencies..."
    
    # Check for SSH
    if ! command -v ssh &> /dev/null; then
        error "SSH is not installed. Please install SSH and try again."
        exit 1
    fi
    
    # Check for SCP
    if ! command -v scp &> /dev/null; then
        error "SCP is not installed. Please install SCP and try again."
        exit 1
    fi
    
    log "All required dependencies are installed!"
}

# ===== Function to create remote directories =====
create_remote_directories() {
    log "Creating directories on the remote server..."
    
    ssh ${SERVER_USER}@${SERVER_HOST} "mkdir -p ${DEPLOY_DIR}/{app,nginx/conf,data/{logs,static,uploads,certbot/conf,certbot/www},scripts}"
    
    if [ $? -ne 0 ]; then
        error "Failed to create directories on the remote server."
        exit 1
    fi
    
    log "Directories created successfully!"
}

# ===== Function to create Flask application files =====
create_flask_app() {
    log "Creating Flask application files..."
    
    # Create directory structure
    mkdir -p temp_deploy/app/db
    
    # Create __init__.py
    cat > temp_deploy/app/__init__.py << 'EOF'
"""
Main package initialization for the Job Scraper application.
"""
# Import the create_app function to make it available from the package
from app.app import create_app
EOF
    
    # Create app.py
    cat > temp_deploy/app/app.py << 'EOF'
"""
Job Scraper Application

A Flask application for scraping and displaying job listings.
"""
import os
from datetime import datetime
from flask import Flask, render_template_string, jsonify, request

def create_app():
    """Application factory pattern."""
    app = Flask(__name__)
    
    # Configure from environment variables
    app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'dev-key-for-testing')
    app.config['DATABASE_URL'] = os.environ.get('DATABASE_URL', 'sqlite:///jobscraper.db')
    
    # Initialize database
    from .db import init_db
    init_db(app)
    
    # Register routes
    
    @app.route('/')
    def index():
        """Home page."""
        return render_template_string("""
        <!DOCTYPE html>
        <html>
        <head>
            <title>Job Scraper</title>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body {
                    font-family: 'Segoe UI', Tahoma, sans-serif;
                    margin: 0;
                    padding: 20px;
                    background-color: #f7f9fc;
                    color: #333;
                }
                .container {
                    max-width: 1200px;
                    margin: 0 auto;
                    background-color: white;
                    padding: 30px;
                    border-radius: 8px;
                    box-shadow: 0 2px 10px rgba(0,0,0,0.1);
                }
                header {
                    border-bottom: 2px solid #eaeaea;
                    padding-bottom: 20px;
                    margin-bottom: 30px;
                }
                h1 {
                    color: #2c5282;
                    margin-top: 0;
                }
                .stats {
                    display: flex;
                    justify-content: space-between;
                    flex-wrap: wrap;
                    margin-bottom: 30px;
                }
                .stat-card {
                    background-color: #ebf4ff;
                    padding: 20px;
                    border-radius: 8px;
                    flex: 1;
                    margin: 10px;
                    min-width: 200px;
                    box-shadow: 0 2px 5px rgba(0,0,0,0.05);
                }
                .stat-card h3 {
                    margin-top: 0;
                    color: #4a5568;
                }
                .stat-card p {
                    font-size: 2em;
                    font-weight: bold;
                    margin: 10px 0;
                    color: #2b6cb0;
                }
                footer {
                    margin-top: 40px;
                    padding-top: 20px;
                    border-top: 1px solid #eaeaea;
                    text-align: center;
                    color: #718096;
                    font-size: 0.9em;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <header>
                    <h1>Job Scraper Dashboard</h1>
                    <p>Welcome to the Job Scraper application. This dashboard provides an overview of the latest job listings.</p>
                </header>
                
                <div class="stats">
                    <div class="stat-card">
                        <h3>Total Jobs</h3>
                        <p>1,245</p>
                    </div>
                    <div class="stat-card">
                        <h3>Jobs Added Today</h3>
                        <p>42</p>
                    </div>
                    <div class="stat-card">
                        <h3>Total Sources</h3>
                        <p>5</p>
                    </div>
                    <div class="stat-card">
                        <h3>Last Update</h3>
                        <p style="font-size: 1.2em;">{{ current_time }}</p>
                    </div>
                </div>
                
                <div>
                    <h2>Recent Jobs</h2>
                    <p>Here you would see a list of the most recently added jobs from multiple sources.</p>
                </div>
                
                <footer>
                    <p>© {{ current_year }} Job Scraper Application | Developed with Flask and PostgreSQL</p>
                </footer>
            </div>
        </body>
        </html>
        """, current_time=datetime.now().strftime("%Y-%m-%d %H:%M"), current_year=datetime.now().year)
    
    @app.route('/api/jobs')
    def api_jobs():
        """API endpoint to get job listings."""
        return jsonify({
            "total": 1245,
            "jobs": [
                {
                    "id": 1,
                    "title": "Senior Software Engineer",
                    "company": "TechCorp",
                    "location": "Remote",
                    "posted_date": "2023-03-20"
                },
                {
                    "id": 2,
                    "title": "Data Scientist",
                    "company": "DataAnalytics Inc",
                    "location": "New York, NY",
                    "posted_date": "2023-03-21"
                },
                {
                    "id": 3,
                    "title": "DevOps Engineer",
                    "company": "CloudSystems",
                    "location": "San Francisco, CA",
                    "posted_date": "2023-03-22"
                }
            ]
        })
    
    @app.route('/health')
    def health():
        """Health check endpoint."""
        return jsonify({
            "status": "healthy",
            "version": "1.0.0",
            "timestamp": datetime.now().isoformat()
        })
    
    return app

if __name__ == '__main__':
    app = create_app()
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 5000)), debug=False)
EOF
    
    # Create db/__init__.py
    cat > temp_deploy/app/db/__init__.py << 'EOF'
"""
Database initialization module for the Job Scraper application.
"""
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import scoped_session, sessionmaker
from sqlalchemy.ext.declarative import declarative_base

Base = declarative_base()
Session = None

def init_db(app):
    """Initialize the database connection."""
    global Session
    
    # Get database URL from environment variable or app config
    database_url = app.config.get('DATABASE_URL')
    
    # Create database engine
    engine = create_engine(
        database_url,
        pool_size=5,
        max_overflow=10,
        pool_recycle=3600,
        pool_pre_ping=True
    )
    
    # Create session factory
    session_factory = sessionmaker(bind=engine)
    Session = scoped_session(session_factory)
    
    # Import models to ensure they're registered with the Base
    from app.db.models import Job, ScraperRun
    
    # Create all tables
    with app.app_context():
        Base.metadata.create_all(bind=engine)
    
    app.logger.info("Database initialized successfully")

def get_session():
    """Get a new database session."""
    if Session is None:
        raise RuntimeError("Database not initialized. Call init_db first.")
    return Session()

def close_session(session):
    """Close a database session."""
    if session:
        session.close()
EOF
    
    # Create db/models.py
    cat > temp_deploy/app/db/models.py << 'EOF'
"""
Database models for the Job Scraper application.
"""
import datetime
from sqlalchemy import Column, Integer, String, DateTime, Boolean, Text, ForeignKey

from app.db import Base

class Job(Base):
    """Job model representing a job listing."""
    
    __tablename__ = 'jobs'
    
    id = Column(Integer, primary_key=True)
    title = Column(String(255), nullable=False)
    company = Column(String(255), nullable=False)
    location = Column(String(255))
    description = Column(Text)
    url = Column(String(512), unique=True, nullable=False)
    posted_date = Column(DateTime)
    found_date = Column(DateTime, default=datetime.datetime.utcnow)
    source = Column(String(100))
    salary_min = Column(Integer)
    salary_max = Column(Integer)
    salary_currency = Column(String(10))
    is_remote = Column(Boolean, default=False)
    is_active = Column(Boolean, default=True)
    
    def __repr__(self):
        return f"<Job(id={self.id}, title='{self.title}', company='{self.company}')>"
    
    def to_dict(self):
        """Convert the job to a dictionary."""
        return {
            "id": self.id,
            "title": self.title,
            "company": self.company,
            "location": self.location,
            "url": self.url,
            "posted_date": self.posted_date.isoformat() if self.posted_date else None,
            "found_date": self.found_date.isoformat() if self.found_date else None,
            "source": self.source,
            "salary_min": self.salary_min,
            "salary_max": self.salary_max,
            "salary_currency": self.salary_currency,
            "is_remote": self.is_remote,
            "is_active": self.is_active
        }

class ScraperRun(Base):
    """Model to track scraper runs."""
    
    __tablename__ = 'scraper_runs'
    
    id = Column(Integer, primary_key=True)
    source = Column(String(100), nullable=False)
    start_time = Column(DateTime, default=datetime.datetime.utcnow)
    end_time = Column(DateTime)
    jobs_found = Column(Integer, default=0)
    jobs_added = Column(Integer, default=0)
    status = Column(String(20), default='running')  # running, completed, failed
    error = Column(Text)
    
    def __repr__(self):
        return f"<ScraperRun(id={self.id}, source='{self.source}', status='{self.status}')>"
    
    def to_dict(self):
        """Convert the scraper run to a dictionary."""
        return {
            "id": self.id,
            "source": self.source,
            "start_time": self.start_time.isoformat() if self.start_time else None,
            "end_time": self.end_time.isoformat() if self.end_time else None,
            "jobs_found": self.jobs_found,
            "jobs_added": self.jobs_added,
            "status": self.status,
            "error": self.error
        }
EOF
    
    # Create Dockerfile
    cat > temp_deploy/app/Dockerfile << 'EOF'
FROM python:3.11-slim

# Set environment variables
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Create necessary directories
RUN mkdir -p /app/logs /app/static /app/uploads /app/data

# Copy application code
COPY . .

# Expose port
EXPOSE 5000

# Set entry point
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "--workers", "3", "--timeout", "60", "app:create_app()"]
EOF
    
    # Create requirements.txt
    cat > temp_deploy/app/requirements.txt << 'EOF'
Flask==2.3.3
gunicorn==21.2.0
SQLAlchemy==2.0.22
psycopg2-binary==2.9.9
redis==5.0.1
Flask-SQLAlchemy==3.1.1
Flask-Migrate==4.0.5
Flask-Redis==0.4.0
Flask-WTF==1.2.1
prometheus-client==0.19.0
EOF
    
    log "Flask application files created successfully!"
}

# ===== Function to create Nginx configuration =====
create_nginx_config() {
    log "Creating Nginx configuration..."
    
    # Create directory
    mkdir -p temp_deploy/nginx/conf
    
    # Create default.conf
    cat > temp_deploy/nginx/conf/default.conf << 'EOF'
server {
    listen 80;
    server_name upgrade4u.online;

    access_log /var/log/nginx/jobscraper_access.log;
    error_log /var/log/nginx/jobscraper_error.log;

    location / {
        proxy_pass http://web:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /static {
        alias /usr/share/nginx/html/static;
        expires 30d;
    }

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    # Add security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
}
EOF
    
    # Create SSL template
    cat > temp_deploy/nginx/conf/ssl.conf.template << 'EOF'
server {
    listen 443 ssl;
    server_name upgrade4u.online;

    ssl_certificate /etc/letsencrypt/live/upgrade4u.online/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/upgrade4u.online/privkey.pem;
    include /etc/letsencrypt/options-ssl-nginx.conf;
    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;

    access_log /var/log/nginx/jobscraper_access.log;
    error_log /var/log/nginx/jobscraper_error.log;

    location / {
        proxy_pass http://web:5000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /static {
        alias /usr/share/nginx/html/static;
        expires 30d;
    }

    # Add security headers
    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
}

server {
    listen 80;
    server_name upgrade4u.online;
    
    location / {
        return 301 https://$host$request_uri;
    }
    
    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }
}
EOF
    
    log "Nginx configuration created successfully!"
}

# ===== Function to create Docker Compose file =====
create_docker_compose() {
    log "Creating Docker Compose configuration..."
    
    cat > temp_deploy/docker-compose.yml << 'EOF'
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
    
    log "Docker Compose configuration created successfully!"
}

# ===== Function to create remote deployment script =====
create_remote_script() {
    log "Creating remote deployment script..."
    
    mkdir -p temp_deploy/scripts
    
    cat > temp_deploy/scripts/deploy_remote.sh << 'EOF'
#!/bin/bash

# Colors for terminal output
GREEN="\033[0;32m"
YELLOW="\033[0;33m"
RED="\033[0;31m"
BLUE="\033[0;34m"
NC="\033[0m" # No Color

# Logging functions
log() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    error "This script must be run as root"
    exit 1
fi

# Configuration
DOMAIN="upgrade4u.online"
EMAIL="aliazimidarmian@gmail.com"
DEPLOY_DIR="/opt/jobscraper"

log "Starting deployment of Job Scraper application..."

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    log "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    rm get-docker.sh
else
    log "Docker is already installed."
fi

# Check if Docker Compose is installed
if ! command -v docker-compose &> /dev/null; then
    log "Installing Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
else
    log "Docker Compose is already installed."
fi

# Stop system Nginx if running
if systemctl is-active --quiet nginx; then
    log "Stopping system Nginx..."
    systemctl stop nginx
fi

# Start Docker services
log "Starting Docker services..."
cd ${DEPLOY_DIR}
docker-compose down -v || true
docker-compose up -d

# Set up SSL certificates
log "Setting up SSL certificates..."
sleep 10 # Wait for Nginx to start

# Create SSL certificate
docker run --rm \
    -v ${DEPLOY_DIR}/data/certbot/conf:/etc/letsencrypt \
    -v ${DEPLOY_DIR}/data/certbot/www:/var/www/certbot \
    certbot/certbot \
    certonly --webroot \
    --webroot-path=/var/www/certbot \
    --email ${EMAIL} \
    --agree-tos \
    --no-eff-email \
    -d ${DOMAIN} \
    || warn "Failed to obtain SSL certificate. The site will still work over HTTP."

# If certificate was obtained, update Nginx config
if [ -d "${DEPLOY_DIR}/data/certbot/conf/live/${DOMAIN}" ]; then
    log "SSL certificate obtained successfully. Updating Nginx configuration..."
    cp nginx/conf/ssl.conf.template nginx/conf/default.conf
    docker-compose exec -T nginx nginx -s reload
    log "Nginx configuration updated. The site is now available over HTTPS."
else
    warn "No SSL certificate found. The site will only be available over HTTP."
fi

log "Deployment completed successfully!"
log "Application is now available at: http://${DOMAIN}"
if [ -d "${DEPLOY_DIR}/data/certbot/conf/live/${DOMAIN}" ]; then
    log "You can also access it securely at: https://${DOMAIN}"
fi

# Show status
docker-compose ps
EOF

    chmod +x temp_deploy/scripts/deploy_remote.sh
    
    log "Remote deployment script created successfully!"
}

# ===== Function to create a tar archive of the deployment files =====
create_tar_archive() {
    log "Creating tar archive of deployment files..."
    
    cd temp_deploy
    tar -czf ../deploy.tar.gz .
    cd ..
    
    log "Tar archive created successfully!"
}

# ===== Function to upload files to server =====
upload_files() {
    log "Uploading files to server..."
    
    scp deploy.tar.gz ${SERVER_USER}@${SERVER_HOST}:${DEPLOY_DIR}/
    
    log "Files uploaded successfully!"
}

# ===== Function to extract files and run deployment on server =====
run_remote_deployment() {
    log "Extracting files and running deployment on server..."
    
    ssh ${SERVER_USER}@${SERVER_HOST} "cd ${DEPLOY_DIR} && tar -xzf deploy.tar.gz && chmod +x scripts/deploy_remote.sh && ./scripts/deploy_remote.sh"
    
    log "Remote deployment executed!"
}

# ===== Function to clean up temporary files =====
cleanup() {
    log "Cleaning up temporary files..."
    
    rm -rf temp_deploy
    rm -f deploy.tar.gz
    
    log "Cleanup completed!"
}

# ===== Main function =====
main() {
    log "Starting Job Scraper deployment..."
    
    # Check dependencies
    check_dependencies
    
    # Create remote directories
    create_remote_directories
    
    # Create application files
    create_flask_app
    
    # Create Nginx configuration
    create_nginx_config
    
    # Create Docker Compose file
    create_docker_compose
    
    # Create remote deployment script
    create_remote_script
    
    # Create tar archive
    create_tar_archive
    
    # Upload files
    upload_files
    
    # Run remote deployment
    run_remote_deployment
    
    # Clean up
    cleanup
    
    log "Deployment process completed!"
    log "The application should now be accessible at: http://${DOMAIN}"
    log "After SSL setup, it should also be accessible at: https://${DOMAIN}"
}

# Run the main function
main 