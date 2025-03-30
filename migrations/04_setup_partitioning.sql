-- Script to set up table partitioning for the jobs table

-- Enable pg_partman extension if not already enabled
CREATE EXTENSION IF NOT EXISTS pg_partman;

-- First, we need to recreate the jobs table as a partitioned table
-- 1. Create a new jobs_partitioned table with the same structure but partitioned by created_at
CREATE TABLE IF NOT EXISTS jobs_partitioned (
    id SERIAL,
    title TEXT NOT NULL,
    company_id INTEGER REFERENCES companies(id),
    description TEXT,
    salary_min INTEGER,
    salary_max INTEGER,
    location_json JSONB,
    job_post_categories JSONB,
    url TEXT,
    tg_channel TEXT,
    tg_message_id INTEGER,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    job_batch_id INTEGER,
    parent_id INTEGER,
    tags JSONB,
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- 2. Create partitions for the jobs table (monthly partitions for the last 2 years and future year)
SELECT create_parent(
    'public.jobs_partitioned',
    'created_at',
    'native',
    'monthly',
    NULL,
    24, -- Keep 24 months of partitions 
    NULL,
    NULL,
    true
);

-- 3. Create partition maintenance function to be run by cron
CREATE OR REPLACE FUNCTION maintain_partitions()
RETURNS void AS $$
BEGIN
    PERFORM run_maintenance(p_analyze := false);
END;
$$ LANGUAGE plpgsql;

-- 4. Comment explaining how to schedule the maintenance
COMMENT ON FUNCTION maintain_partitions() IS 
'This function should be scheduled to run daily using a cron job:
Example: 
0 0 * * * psql -U postgres -d jobsdb -c "SELECT maintain_partitions();"';

-- 5. Create indexes on the partitioned table for better performance
CREATE INDEX IF NOT EXISTS idx_jobs_partitioned_company_id ON jobs_partitioned(company_id);
CREATE INDEX IF NOT EXISTS idx_jobs_partitioned_created_at ON jobs_partitioned(created_at);
CREATE INDEX IF NOT EXISTS idx_jobs_partitioned_job_batch_id ON jobs_partitioned(job_batch_id);
CREATE INDEX IF NOT EXISTS idx_jobs_partitioned_title_tsvector ON jobs_partitioned USING GIN (to_tsvector('persian', title));
CREATE INDEX IF NOT EXISTS idx_jobs_partitioned_description_tsvector ON jobs_partitioned USING GIN (to_tsvector('persian', description));

-- Function to migrate data to partitioned table (comment out to run manually)
/* 
CREATE OR REPLACE FUNCTION migrate_to_partitioned_jobs()
RETURNS void AS $$
BEGIN
    INSERT INTO jobs_partitioned 
    SELECT * FROM jobs 
    ON CONFLICT (id, created_at) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION migrate_to_partitioned_jobs() IS 
'This function should be run manually after proper backup:
SELECT migrate_to_partitioned_jobs();
After successful migration, you can rename tables:
ALTER TABLE jobs RENAME TO jobs_old;
ALTER TABLE jobs_partitioned RENAME TO jobs;';
*/

-- Setup similar partitioning for job_batches table
CREATE TABLE IF NOT EXISTS job_batches_partitioned (
    id SERIAL,
    site TEXT NOT NULL,
    query JSONB,
    status TEXT NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    total_jobs INTEGER DEFAULT 0,
    new_jobs INTEGER DEFAULT 0,
    updated_jobs INTEGER DEFAULT 0,
    PRIMARY KEY (id, created_at)
) PARTITION BY RANGE (created_at);

-- Create partitions for job_batches (monthly partitions)
SELECT create_parent(
    'public.job_batches_partitioned',
    'created_at',
    'native',
    'monthly',
    NULL,
    24, -- Keep 24 months of partitions
    NULL,
    NULL,
    true
);

-- Create indexes on the partitioned table
CREATE INDEX IF NOT EXISTS idx_job_batches_partitioned_site ON job_batches_partitioned(site);
CREATE INDEX IF NOT EXISTS idx_job_batches_partitioned_created_at ON job_batches_partitioned(created_at);
CREATE INDEX IF NOT EXISTS idx_job_batches_partitioned_status ON job_batches_partitioned(status);

-- Function to migrate data to partitioned job_batches (comment out to run manually)
/*
CREATE OR REPLACE FUNCTION migrate_to_partitioned_job_batches()
RETURNS void AS $$
BEGIN
    INSERT INTO job_batches_partitioned 
    SELECT * FROM job_batches 
    ON CONFLICT (id, created_at) DO NOTHING;
END;
$$ LANGUAGE plpgsql;

COMMENT ON FUNCTION migrate_to_partitioned_job_batches() IS 
'This function should be run manually after proper backup:
SELECT migrate_to_partitioned_job_batches();
After successful migration, you can rename tables:
ALTER TABLE job_batches RENAME TO job_batches_old;
ALTER TABLE job_batches_partitioned RENAME TO job_batches;';
*/

-- Add comment about the partitioning setup
COMMENT ON TABLE jobs_partitioned IS 'Jobs table partitioned by created_at date (monthly). Use the maintain_partitions() function to keep partitions up to date.';
COMMENT ON TABLE job_batches_partitioned IS 'Job batches table partitioned by created_at date (monthly).';

-- 6. Create a view that points to either the old or new table to make transition seamless
CREATE OR REPLACE VIEW jobs_view AS
SELECT * FROM jobs_partitioned;

-- 7. Create trigger function to route inserts through the view
CREATE OR REPLACE FUNCTION jobs_view_insert_trigger()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO jobs_partitioned VALUES (NEW.*);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER jobs_view_insert
INSTEAD OF INSERT ON jobs_view
FOR EACH ROW EXECUTE FUNCTION jobs_view_insert_trigger();

-- 8. Create similar triggers for UPDATE and DELETE if needed
CREATE OR REPLACE FUNCTION jobs_view_update_trigger()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE jobs_partitioned
    SET
        title = NEW.title,
        url = NEW.url,
        locations = NEW.locations,
        work_types = NEW.work_types,
        salary = NEW.salary,
        gender = NEW.gender,
        tags = NEW.tags,
        item_index = NEW.item_index,
        job_post_categories = NEW.job_post_categories,
        company_fa_name = NEW.company_fa_name,
        province_match_city = NEW.province_match_city,
        normalize_salary_min = NEW.normalize_salary_min,
        normalize_salary_max = NEW.normalize_salary_max,
        payment_method = NEW.payment_method,
        district = NEW.district,
        company_title_fa = NEW.company_title_fa,
        job_board_id = NEW.job_board_id,
        job_board_title_en = NEW.job_board_title_en,
        activation_time = NEW.activation_time,
        company_id = NEW.company_id,
        company_name_fa = NEW.company_name_fa,
        company_name_en = NEW.company_name_en,
        company_about = NEW.company_about,
        company_url = NEW.company_url,
        location_ids = NEW.location_ids,
        tag_number = NEW.tag_number,
        raw_data = NEW.raw_data,
        updated_at = CURRENT_TIMESTAMP,
        batch_id = NEW.batch_id,
        batch_date = NEW.batch_date
    WHERE id = NEW.id;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER jobs_view_update
INSTEAD OF UPDATE ON jobs_view
FOR EACH ROW EXECUTE FUNCTION jobs_view_update_trigger();

CREATE OR REPLACE FUNCTION jobs_view_delete_trigger()
RETURNS TRIGGER AS $$
BEGIN
    DELETE FROM jobs_partitioned WHERE id = OLD.id;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER jobs_view_delete
INSTEAD OF DELETE ON jobs_view
FOR EACH ROW EXECUTE FUNCTION jobs_view_delete_trigger();

-- 9. Add function to create future partitions automatically
CREATE OR REPLACE FUNCTION create_future_job_partitions(years_ahead int DEFAULT 1)
RETURNS void AS $$
DECLARE
    partition_date date;
    partition_end_date date;
    year_val int;
    month_val int;
BEGIN
    -- Get the current date
    partition_date := date_trunc('month', CURRENT_DATE) + interval '1 month';
    
    -- Loop for the number of years ahead
    FOR i IN 1..years_ahead*12 LOOP
        year_val := EXTRACT(YEAR FROM partition_date);
        month_val := EXTRACT(MONTH FROM partition_date);
        partition_end_date := partition_date + interval '1 month';
        
        -- Create the partition if it doesn't exist
        EXECUTE format('
            CREATE TABLE IF NOT EXISTS jobs_y%sm%s PARTITION OF jobs_partitioned
            FOR VALUES FROM (''%s'') TO (''%s'')',
            year_val,
            LPAD(month_val::text, 2, '0'),
            partition_date,
            partition_end_date
        );
        
        -- Advance to next month
        partition_date := partition_end_date;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Setup table partitioning for better performance with large datasets

-- Check if pg_partman extension is available and install it if needed
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 
        FROM pg_extension 
        WHERE extname = 'pg_partman'
    ) THEN
        -- We can't directly install extensions in SQL, so we'll just raise a notice
        RAISE NOTICE 'The pg_partman extension is not installed. Please install it using: CREATE EXTENSION pg_partman;';
    END IF;
END $$;

-- Create a partitioning function for jobs table
CREATE OR REPLACE FUNCTION create_job_partitions(
    p_start_year INTEGER, 
    p_end_year INTEGER
) RETURNS void AS $$
DECLARE
    partition_name TEXT;
    start_date DATE;
    end_date DATE;
    current_year INTEGER;
    current_month INTEGER;
BEGIN
    -- Create partitioned jobs table if it doesn't exist
    IF NOT EXISTS (
        SELECT FROM information_schema.tables 
        WHERE table_schema = 'public' AND table_name = 'jobs_partitioned'
    ) THEN
        CREATE TABLE jobs_partitioned (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            description TEXT,
            company_id INTEGER REFERENCES companies(id),
            url TEXT,
            source TEXT,
            salary_min NUMERIC,
            salary_max NUMERIC,
            salary_currency TEXT,
            created_at TIMESTAMP NOT NULL,
            updated_at TIMESTAMP,
            job_batch_id INTEGER REFERENCES job_batches_partitioned(id),
            is_active BOOLEAN DEFAULT TRUE,
            PRIMARY KEY (id, created_at)
        ) PARTITION BY RANGE (created_at);
        
        -- Create indexes
        CREATE INDEX IF NOT EXISTS idx_jobs_partitioned_company_id ON jobs_partitioned (company_id);
        CREATE INDEX IF NOT EXISTS idx_jobs_partitioned_created_at ON jobs_partitioned (created_at);
        CREATE INDEX IF NOT EXISTS idx_jobs_partitioned_job_batch_id ON jobs_partitioned (job_batch_id);
        
        RAISE NOTICE 'Created partitioned jobs table';
    END IF;
    
    -- Get current year and month
    current_year := EXTRACT(YEAR FROM CURRENT_DATE);
    current_month := EXTRACT(MONTH FROM CURRENT_DATE);
    
    -- Create year partitions
    FOR year IN p_start_year..p_end_year LOOP
        -- Create monthly partitions for each year
        FOR month IN 1..12 LOOP
            partition_name := 'jobs_p' || year || '_' || LPAD(month::TEXT, 2, '0');
            start_date := make_date(year, month, 1);
            
            IF month = 12 THEN
                end_date := make_date(year + 1, 1, 1);
            ELSE
                end_date := make_date(year, month + 1, 1);
            END IF;
            
            -- Only create partitions if they don't exist
            IF NOT EXISTS (
                SELECT FROM pg_tables 
                WHERE schemaname = 'public' AND tablename = partition_name
            ) THEN
                EXECUTE format(
                    'CREATE TABLE IF NOT EXISTS %I PARTITION OF jobs_partitioned 
                    FOR VALUES FROM (%L) TO (%L)',
                    partition_name, start_date, end_date
                );
                
                RAISE NOTICE 'Created partition %', partition_name;
            END IF;
        END LOOP;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Create function to migrate data from jobs to partitioned table
CREATE OR REPLACE FUNCTION migrate_to_partitioned_jobs() RETURNS INTEGER AS $$
DECLARE
    v_count INTEGER := 0;
BEGIN
    -- Ensure partitions exist before migrating
    PERFORM create_job_partitions(
        EXTRACT(YEAR FROM (SELECT MIN(created_at) FROM jobs))::INTEGER,
        EXTRACT(YEAR FROM (SELECT MAX(created_at) FROM jobs))::INTEGER + 1
    );
    
    -- Insert data from jobs to jobs_partitioned
    INSERT INTO jobs_partitioned (
        id, title, description, company_id, url, source,
        salary_min, salary_max, salary_currency, created_at, updated_at, 
        job_batch_id, is_active
    )
    SELECT 
        j.id,
        j.title,
        j.description,
        c.id AS company_id,
        j.url,
        j.source,
        j.salary_min::NUMERIC,
        j.salary_max::NUMERIC,
        j.salary_currency,
        j.created_at,
        j.updated_at,
        b.id AS job_batch_id,
        j.is_active
    FROM jobs j
    LEFT JOIN companies c ON j.company_name = c.name
    LEFT JOIN job_batches_partitioned b ON 
        DATE(j.created_at) = b.batch_date AND
        COALESCE(j.source, 'unknown') = b.source
    ON CONFLICT (id, created_at) DO NOTHING;
    
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END;
$$ LANGUAGE plpgsql;

-- Create a trigger function to automatically create new partitions
CREATE OR REPLACE FUNCTION create_new_partition_trigger() RETURNS TRIGGER AS $$
DECLARE
    partition_year INTEGER;
    partition_month INTEGER;
BEGIN
    partition_year := EXTRACT(YEAR FROM NEW.created_at);
    partition_month := EXTRACT(MONTH FROM NEW.created_at);
    
    -- Check if partition exists for this date
    IF NOT EXISTS (
        SELECT FROM pg_tables 
        WHERE schemaname = 'public' AND 
              tablename = 'jobs_p' || partition_year || '_' || LPAD(partition_month::TEXT, 2, '0')
    ) THEN
        -- Create partition if it doesn't exist
        PERFORM create_job_partitions(partition_year, partition_year);
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create a trigger to execute before insert
DROP TRIGGER IF EXISTS before_insert_jobs_partitioned ON jobs_partitioned;
CREATE TRIGGER before_insert_jobs_partitioned
BEFORE INSERT ON jobs_partitioned
FOR EACH ROW EXECUTE FUNCTION create_new_partition_trigger();

-- Try to run the partition creation for the next 2 years (even if no data exists yet)
SELECT create_job_partitions(
    EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER,
    EXTRACT(YEAR FROM CURRENT_DATE)::INTEGER + 2
);

-- Try to migrate existing data if available
DO $$
DECLARE
    migrated_count INTEGER;
BEGIN
    IF EXISTS (
        SELECT FROM information_schema.tables 
        WHERE table_schema = 'public' AND table_name = 'jobs'
    ) THEN
        SELECT migrate_to_partitioned_jobs() INTO migrated_count;
        RAISE NOTICE 'Migrated % job records to partitioned table', migrated_count;
    ELSE
        RAISE NOTICE 'No jobs table found, skipping data migration to partitioned table';
    END IF;
END $$; 