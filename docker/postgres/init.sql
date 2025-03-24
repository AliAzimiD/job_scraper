-- Create schema
CREATE SCHEMA IF NOT EXISTS jobdata;

-- Set up extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- Set the search path
SET search_path TO jobdata, public;

-- Create jobs table
CREATE TABLE IF NOT EXISTS jobs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    title VARCHAR(255) NOT NULL,
    company VARCHAR(255) NOT NULL,
    location VARCHAR(255),
    description TEXT,
    url VARCHAR(2048) NOT NULL,
    salary VARCHAR(255),
    posted_date TIMESTAMP,
    job_type VARCHAR(100),
    remote BOOLEAN DEFAULT FALSE,
    tags JSONB,
    source VARCHAR(100),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_jobs_title ON jobs USING GIN (title gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_jobs_company ON jobs USING GIN (company gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_jobs_location ON jobs USING GIN (location gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_jobs_description ON jobs USING GIN (description gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_jobs_tags ON jobs USING GIN (tags);
CREATE INDEX IF NOT EXISTS idx_jobs_posted_date ON jobs (posted_date);
CREATE INDEX IF NOT EXISTS idx_jobs_created_at ON jobs (created_at);
CREATE INDEX IF NOT EXISTS idx_jobs_job_type ON jobs (job_type);
CREATE INDEX IF NOT EXISTS idx_jobs_remote ON jobs (remote);
CREATE INDEX IF NOT EXISTS idx_jobs_source ON jobs (source);

-- Create scraper_status table
CREATE TABLE IF NOT EXISTS scraper_status (
    id SERIAL PRIMARY KEY,
    status VARCHAR(50) NOT NULL,
    start_time TIMESTAMP WITH TIME ZONE,
    end_time TIMESTAMP WITH TIME ZONE,
    pages_scraped INTEGER DEFAULT 0,
    jobs_found INTEGER DEFAULT 0,
    jobs_added INTEGER DEFAULT 0,
    jobs_updated INTEGER DEFAULT 0,
    error_message TEXT,
    config JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create scraper_config table
CREATE TABLE IF NOT EXISTS scraper_config (
    id SERIAL PRIMARY KEY,
    config_name VARCHAR(100) NOT NULL UNIQUE,
    config_data JSONB NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create default scraper configuration
INSERT INTO scraper_config (config_name, config_data)
VALUES ('default', '{
    "max_pages": 5,
    "rate_limit_ms": 1000,
    "max_concurrent_requests": 5,
    "sources": [
        {
            "name": "example_source",
            "enabled": true,
            "url_template": "https://example.com/jobs?page={page}",
            "max_pages": 3
        }
    ],
    "user_agents": [
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.124 Safari/537.36",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/14.0 Safari/605.1.15"
    ]
}')
ON CONFLICT (config_name) DO NOTHING;

-- Create audit_log table for tracking changes
CREATE TABLE IF NOT EXISTS audit_log (
    id SERIAL PRIMARY KEY,
    table_name VARCHAR(100) NOT NULL,
    record_id UUID,
    action VARCHAR(10) NOT NULL,
    old_data JSONB,
    new_data JSONB,
    changed_by VARCHAR(100),
    ip_address VARCHAR(45),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Create function for audit logging
CREATE OR REPLACE FUNCTION log_audit() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' THEN
        INSERT INTO audit_log (table_name, record_id, action, new_data, changed_by)
        VALUES (TG_TABLE_NAME, NEW.id, 'INSERT', row_to_json(NEW), current_user);
    ELSIF TG_OP = 'UPDATE' THEN
        INSERT INTO audit_log (table_name, record_id, action, old_data, new_data, changed_by)
        VALUES (TG_TABLE_NAME, NEW.id, 'UPDATE', row_to_json(OLD), row_to_json(NEW), current_user);
    ELSIF TG_OP = 'DELETE' THEN
        INSERT INTO audit_log (table_name, record_id, action, old_data, changed_by)
        VALUES (TG_TABLE_NAME, OLD.id, 'DELETE', row_to_json(OLD), current_user);
    END IF;
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for audit logging
CREATE TRIGGER jobs_audit
AFTER INSERT OR UPDATE OR DELETE ON jobs
FOR EACH ROW EXECUTE FUNCTION log_audit();

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create triggers for updated_at timestamps
CREATE TRIGGER update_jobs_modtime
BEFORE UPDATE ON jobs
FOR EACH ROW EXECUTE FUNCTION update_modified_column();

CREATE TRIGGER update_scraper_status_modtime
BEFORE UPDATE ON scraper_status
FOR EACH ROW EXECUTE FUNCTION update_modified_column();

CREATE TRIGGER update_scraper_config_modtime
BEFORE UPDATE ON scraper_config
FOR EACH ROW EXECUTE FUNCTION update_modified_column();

-- Grant privileges
GRANT ALL PRIVILEGES ON SCHEMA jobdata TO jobuser;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA jobdata TO jobuser;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA jobdata TO jobuser;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA jobdata TO jobuser;

-- Set search path for user
ALTER ROLE jobuser SET search_path TO jobdata, public; 