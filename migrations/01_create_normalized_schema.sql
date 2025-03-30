-- Migration script to create normalized database schema
-- This creates new normalized tables while preserving the existing ones

-- Drop existing tables if they exist
DO $$ 
BEGIN
    -- Check if we need to drop tables
    IF EXISTS (SELECT FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'jobs') THEN
        RAISE NOTICE 'Dropping existing tables...';
        
        -- Drop existing tables in correct dependency order
        DROP TABLE IF EXISTS jobs_tags CASCADE;
        DROP TABLE IF EXISTS jobs_categories CASCADE;
        DROP TABLE IF EXISTS job_locations CASCADE;
        DROP TABLE IF EXISTS jobs CASCADE;
        DROP TABLE IF EXISTS job_batches CASCADE;
        DROP TABLE IF EXISTS companies CASCADE;
        DROP TABLE IF EXISTS job_tags CASCADE;
        DROP TABLE IF EXISTS job_categories CASCADE;
        DROP TABLE IF EXISTS locations CASCADE;
        DROP TABLE IF EXISTS work_types CASCADE;
        
        -- Drop views
        DROP VIEW IF EXISTS job_stats_by_company CASCADE;
        DROP VIEW IF EXISTS job_posting_trends CASCADE;
        
        -- Drop materialized views
        DROP MATERIALIZED VIEW IF EXISTS mv_job_stats_by_company CASCADE;
        DROP MATERIALIZED VIEW IF EXISTS mv_job_stats_by_tag CASCADE;
        DROP MATERIALIZED VIEW IF EXISTS mv_job_stats_by_category CASCADE;
        DROP MATERIALIZED VIEW IF EXISTS mv_job_stats_by_location CASCADE;
        DROP MATERIALIZED VIEW IF EXISTS mv_tag_co_occurrence CASCADE;
        DROP MATERIALIZED VIEW IF EXISTS mv_category_tag_relationship CASCADE;
        DROP MATERIALIZED VIEW IF EXISTS mv_job_posting_trends CASCADE;
    ELSE
        RAISE NOTICE 'Fresh installation, creating new schema...';
    END IF;
END $$;

-- Create normalized tables

-- Companies table
CREATE TABLE IF NOT EXISTS companies (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    url VARCHAR(255),
    logo_url VARCHAR(255),
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_company_name UNIQUE (name)
);

-- Work Types table
CREATE TABLE IF NOT EXISTS work_types (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_work_type_name UNIQUE (name)
);

-- Locations table
CREATE TABLE IF NOT EXISTS locations (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    country VARCHAR(100),
    city VARCHAR(100),
    is_remote BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_location_name UNIQUE (name)
);

-- Tags table
CREATE TABLE IF NOT EXISTS job_tags (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_tag_name UNIQUE (name)
);

-- Categories table
CREATE TABLE IF NOT EXISTS job_categories (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    description TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT unique_category_name UNIQUE (name)
);

-- Job Batches table (for tracking scraping batches)
CREATE TABLE IF NOT EXISTS job_batches_new (
    id SERIAL PRIMARY KEY,
    batch_date DATE NOT NULL,
    source VARCHAR(100) NOT NULL,
    job_count INTEGER DEFAULT 0,
    status VARCHAR(50) DEFAULT 'processing',
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP,
    notes TEXT,
    CONSTRAINT unique_batch_date_source UNIQUE (batch_date, source)
);

-- Create partitioned job batches table
CREATE TABLE IF NOT EXISTS job_batches_partitioned (
    id SERIAL,
    batch_date DATE NOT NULL,
    source VARCHAR(100) NOT NULL,
    job_count INTEGER DEFAULT 0,
    status VARCHAR(50) DEFAULT 'processing',
    started_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP,
    notes TEXT,
    PRIMARY KEY (id, batch_date)
) PARTITION BY RANGE (batch_date);

-- Create partitions for the current year by month
DO $$
DECLARE
    current_year INTEGER := EXTRACT(YEAR FROM CURRENT_DATE);
    partition_name TEXT;
    start_date DATE;
    end_date DATE;
BEGIN
    FOR month IN 1..12 LOOP
        partition_name := 'job_batches_p' || current_year || '_' || LPAD(month::TEXT, 2, '0');
        start_date := make_date(current_year, month, 1);
        
        IF month = 12 THEN
            end_date := make_date(current_year + 1, 1, 1);
        ELSE
            end_date := make_date(current_year, month + 1, 1);
        END IF;
        
        EXECUTE format('CREATE TABLE IF NOT EXISTS %I PARTITION OF job_batches_partitioned 
                        FOR VALUES FROM (%L) TO (%L)',
                        partition_name, start_date, end_date);
    END LOOP;
END $$;

-- Insert function to handle job data
CREATE OR REPLACE FUNCTION insert_or_update_job(
    p_title TEXT,
    p_description TEXT,
    p_company_name TEXT,
    p_company_url TEXT,
    p_location_name TEXT,
    p_is_remote BOOLEAN,
    p_work_type_name TEXT,
    p_salary_min NUMERIC,
    p_salary_max NUMERIC,
    p_currency TEXT,
    p_url TEXT,
    p_source TEXT,
    p_batch_date DATE,
    p_tags TEXT[],
    p_categories TEXT[]
) RETURNS INTEGER AS $$
DECLARE
    v_company_id INTEGER;
    v_location_id INTEGER;
    v_work_type_id INTEGER;
    v_job_id INTEGER;
    v_tag_id INTEGER;
    v_category_id INTEGER;
    v_batch_id INTEGER;
    v_tag TEXT;
    v_category TEXT;
BEGIN
    -- Get or create company
    SELECT id INTO v_company_id FROM companies WHERE name = p_company_name;
    
    IF v_company_id IS NULL THEN
        INSERT INTO companies (name, url)
        VALUES (p_company_name, p_company_url)
        RETURNING id INTO v_company_id;
    END IF;
    
    -- Get or create location
    SELECT id INTO v_location_id FROM locations WHERE name = p_location_name;
    
    IF v_location_id IS NULL THEN
        INSERT INTO locations (name, is_remote)
        VALUES (p_location_name, p_is_remote)
        RETURNING id INTO v_location_id;
    END IF;
    
    -- Get or create work type
    SELECT id INTO v_work_type_id FROM work_types WHERE name = p_work_type_name;
    
    IF v_work_type_id IS NULL THEN
        INSERT INTO work_types (name)
        VALUES (p_work_type_name)
        RETURNING id INTO v_work_type_id;
    END IF;
    
    -- Get or create batch
    SELECT id INTO v_batch_id 
    FROM job_batches_partitioned
    WHERE batch_date = p_batch_date AND source = p_source;
    
    IF v_batch_id IS NULL THEN
        INSERT INTO job_batches_partitioned (batch_date, source)
        VALUES (p_batch_date, p_source)
        RETURNING id INTO v_batch_id;
    END IF;
    
    -- Return the job_id for further processing
    RETURN v_job_id;
END;
$$ LANGUAGE plpgsql;

-- Create indexes for better query performance
CREATE INDEX IF NOT EXISTS idx_companies_name ON companies (name);
CREATE INDEX IF NOT EXISTS idx_locations_name ON locations (name);
CREATE INDEX IF NOT EXISTS idx_work_types_name ON work_types (name);
CREATE INDEX IF NOT EXISTS idx_job_tags_name ON job_tags (name);
CREATE INDEX IF NOT EXISTS idx_job_categories_name ON job_categories (name);
CREATE INDEX IF NOT EXISTS idx_job_batches_date ON job_batches_new (batch_date);
CREATE INDEX IF NOT EXISTS idx_job_batches_partitioned_date ON job_batches_partitioned (batch_date);

-- If we have sample data, populate initial work types
INSERT INTO work_types (name)
VALUES 
    ('Full-time'),
    ('Part-time'),
    ('Contract'),
    ('Freelance'),
    ('Internship')
ON CONFLICT (name) DO NOTHING;

-- Create sample locations
INSERT INTO locations (name, is_remote)
VALUES 
    ('Remote', TRUE),
    ('Tehran', FALSE),
    ('Mashhad', FALSE),
    ('Isfahan', FALSE),
    ('Shiraz', FALSE)
ON CONFLICT (name) DO NOTHING;

-- Function to update timestamp on updates
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add trigger for updated_at
CREATE TRIGGER update_companies_updated_at
BEFORE UPDATE ON companies
FOR EACH ROW
EXECUTE FUNCTION update_updated_at_column();

-- 2. Create Tags Table
CREATE TABLE IF NOT EXISTS jobs_tags (
    job_id TEXT REFERENCES jobs(id) ON DELETE CASCADE,
    tag_id INTEGER REFERENCES job_tags(id) ON DELETE CASCADE,
    PRIMARY KEY (job_id, tag_id)
);

-- 3. Create Categories Table
CREATE TABLE IF NOT EXISTS jobs_categories (
    job_id TEXT REFERENCES jobs(id) ON DELETE CASCADE,
    category_id INTEGER REFERENCES job_categories(id) ON DELETE CASCADE,
    position INTEGER, -- To preserve order if needed
    PRIMARY KEY (job_id, category_id)
);

-- 4. Create Locations Table
CREATE TABLE IF NOT EXISTS job_locations (
    job_id TEXT REFERENCES jobs(id) ON DELETE CASCADE,
    location_id INTEGER REFERENCES locations(id) ON DELETE CASCADE,
    PRIMARY KEY (job_id, location_id)
);

-- 5. Create Work Types Table
CREATE TABLE IF NOT EXISTS job_work_types (
    job_id TEXT REFERENCES jobs(id) ON DELETE CASCADE,
    work_type_id INTEGER REFERENCES work_types(id) ON DELETE CASCADE,
    PRIMARY KEY (job_id, work_type_id)
);

-- Add indexes for improved performance
CREATE INDEX IF NOT EXISTS idx_companies_name_fa ON companies(name_fa);
CREATE INDEX IF NOT EXISTS idx_companies_name_en ON companies(name_en);
CREATE INDEX IF NOT EXISTS idx_job_tags_name_fa ON job_tags(name_fa);
CREATE INDEX IF NOT EXISTS idx_job_categories_parent_id ON job_categories(parent_id);
CREATE INDEX IF NOT EXISTS idx_jobs_tags_job_id ON jobs_tags(job_id);
CREATE INDEX IF NOT EXISTS idx_jobs_tags_tag_id ON jobs_tags(tag_id);
CREATE INDEX IF NOT EXISTS idx_jobs_categories_job_id ON jobs_categories(job_id);
CREATE INDEX IF NOT EXISTS idx_jobs_categories_category_id ON jobs_categories(category_id);
CREATE INDEX IF NOT EXISTS idx_locations_parent_id ON locations(parent_id);
CREATE INDEX IF NOT EXISTS idx_job_locations_job_id ON job_locations(job_id);
CREATE INDEX IF NOT EXISTS idx_job_locations_location_id ON job_locations(location_id);
CREATE INDEX IF NOT EXISTS idx_job_work_types_job_id ON job_work_types(job_id);
CREATE INDEX IF NOT EXISTS idx_job_work_types_work_type_id ON job_work_types(work_type_id);

-- GIN indexes for text search
CREATE INDEX IF NOT EXISTS idx_job_tags_name_fa_gin ON job_tags USING GIN (to_tsvector('simple', name_fa));
CREATE INDEX IF NOT EXISTS idx_job_categories_name_fa_gin ON job_categories USING GIN (to_tsvector('simple', name_fa));
CREATE INDEX IF NOT EXISTS idx_locations_name_fa_gin ON locations USING GIN (to_tsvector('simple', name_fa)); 