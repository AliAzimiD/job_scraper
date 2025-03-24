-- Create jobs table if it doesn't exist
CREATE TABLE IF NOT EXISTS public.jobs (
    id VARCHAR(255) PRIMARY KEY,
    title TEXT NOT NULL,
    company_name_en TEXT,
    company_name_fa TEXT,
    description TEXT,
    url TEXT,
    activation_time TIMESTAMP WITH TIME ZONE,
    expiration_time TIMESTAMP WITH TIME ZONE,
    locations JSONB,
    job_categories JSONB,
    tags JSONB,
    work_types JSONB,
    salary JSONB,
    raw_data JSONB,
    job_post_categories JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    batch_id VARCHAR(255)
);

-- Create batches table if it doesn't exist
CREATE TABLE IF NOT EXISTS public.scraper_batches (
    batch_id VARCHAR(255) PRIMARY KEY,
    start_time TIMESTAMP WITH TIME ZONE NOT NULL,
    end_time TIMESTAMP WITH TIME ZONE,
    job_count INTEGER DEFAULT 0,
    status VARCHAR(50) DEFAULT 'in_progress',
    error_message TEXT,
    processing_time FLOAT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create scraper_stats table if it doesn't exist
CREATE TABLE IF NOT EXISTS public.scraper_stats (
    id SERIAL PRIMARY KEY,
    run_date TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    total_pages INTEGER DEFAULT 0,
    total_jobs INTEGER DEFAULT 0,
    new_jobs INTEGER DEFAULT 0,
    updated_jobs INTEGER DEFAULT 0,
    errors INTEGER DEFAULT 0,
    duration_seconds FLOAT,
    status VARCHAR(50),
    batch_id VARCHAR(255) REFERENCES public.scraper_batches(batch_id),
    notes TEXT
);

-- Create an index on jobs.batch_id to improve performance
CREATE INDEX IF NOT EXISTS idx_jobs_batch_id ON public.jobs(batch_id);
CREATE INDEX IF NOT EXISTS idx_jobs_activation_time ON public.jobs(activation_time);

-- Create timestamp update function
CREATE OR REPLACE FUNCTION update_modified_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create a trigger to automatically update the updated_at timestamp
CREATE TRIGGER trg_jobs_updated_at
BEFORE UPDATE ON public.jobs
FOR EACH ROW
EXECUTE FUNCTION update_modified_column(); 