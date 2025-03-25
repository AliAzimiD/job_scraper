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
    SQLALCHEMY_SILENCE_UBER_WARNING=1 \
    PYTHONPATH=/app

# Create necessary directories
RUN mkdir -p /app/logs /app/data /app/uploads

# Copy requirements first to leverage Docker cache
COPY requirements.txt .

# Install Python dependencies
RUN pip install --retries 5 -r requirements.txt && \
    pip install flask-bootstrap prometheus-client

# Copy the application code
COPY . .

# Create default configuration file if it doesn't exist
RUN if [ ! -f config/app_config.yaml ]; then \
    mkdir -p config && \
    echo "app:\n  environment: production\n  debug: false" > config/app_config.yaml; \
    fi

# Set up volume mounts
VOLUME ["/app/data", "/app/logs", "/app/uploads"]

# Expose port for the web application
EXPOSE 5000

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:5000/health || exit 1

# Start the application
CMD ["python", "main.py"]
