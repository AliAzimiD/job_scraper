FROM apache/superset:latest

USER root

# Install additional dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    build-essential \
    default-libmysqlclient-dev \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Install database drivers and other requirements
RUN pip install --no-cache-dir \
    psycopg2-binary==2.9.6 \
    sqlalchemy-redshift==0.8.12 \
    sqlalchemy==1.4.47 \
    redis==4.5.5

# Copy configuration
COPY superset_config.py /app/pythonpath/

USER superset
