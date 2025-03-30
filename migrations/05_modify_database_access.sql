-- Script to create database functions and views for abstraction

-- 1. Create a unified jobs view that includes data from normalized tables
CREATE OR REPLACE VIEW jobs_unified AS
SELECT 
    j.*,
    c.name_fa AS company_name,
    c.about AS company_about,
    c.website AS company_website,
    array_agg(DISTINCT t.name) FILTER (WHERE t.name IS NOT NULL) AS tag_names,
    array_agg(DISTINCT cat.name) FILTER (WHERE cat.name IS NOT NULL) AS category_names,
    array_agg(DISTINCT l.name) FILTER (WHERE l.name IS NOT NULL) AS location_names,
    array_agg(DISTINCT wt.name) FILTER (WHERE wt.name IS NOT NULL) AS work_type_names
FROM 
    jobs_partitioned j
LEFT JOIN 
    companies c ON j.company_id = c.id
LEFT JOIN 
    jobs_tags jt ON j.id = jt.job_id
LEFT JOIN 
    job_tags t ON jt.tag_id = t.id
LEFT JOIN 
    jobs_categories jc ON j.id = jc.job_id
LEFT JOIN 
    job_categories cat ON jc.category_id = cat.id
LEFT JOIN 
    job_locations jl ON j.id = jl.job_id
LEFT JOIN 
    locations l ON jl.location_id = l.id
LEFT JOIN 
    job_work_types jwt ON j.id = jwt.job_id
LEFT JOIN 
    work_types wt ON jwt.work_type_id = wt.id
GROUP BY 
    j.id, c.id;

-- 2. Create a function to insert new jobs with normalized data
CREATE OR REPLACE FUNCTION insert_job(
    p_id TEXT,
    p_title TEXT,
    p_url TEXT,
    p_locations JSONB,
    p_work_types JSONB,
    p_salary JSONB,
    p_gender TEXT,
    p_tags JSONB,
    p_item_index INTEGER,
    p_job_post_categories JSONB,
    p_company_fa_name TEXT,
    p_province_match_city TEXT,
    p_normalize_salary_min DOUBLE PRECISION,
    p_normalize_salary_max DOUBLE PRECISION,
    p_payment_method TEXT,
    p_district TEXT,
    p_company_title_fa TEXT,
    p_job_board_id TEXT,
    p_job_board_title_en TEXT,
    p_activation_time TIMESTAMP WITHOUT TIME ZONE,
    p_company_id TEXT,
    p_company_name_fa TEXT,
    p_company_name_en TEXT,
    p_company_about TEXT,
    p_company_url TEXT,
    p_location_ids TEXT,
    p_tag_number TEXT,
    p_raw_data JSONB,
    p_batch_id TEXT,
    p_batch_date TIMESTAMP WITHOUT TIME ZONE
) RETURNS TEXT AS $$
DECLARE
    v_tag JSONB;
    v_category JSONB;
    v_location JSONB;
    v_work_type JSONB;
    v_tag_id INTEGER;
    v_category_id INTEGER;
    v_location_id INTEGER;
    v_work_type_id INTEGER;
BEGIN
    -- Insert or update company information
    IF p_company_id IS NOT NULL THEN
        INSERT INTO companies (
            id, name_fa, name_en, about, website, logo_url
        ) VALUES (
            p_company_id, 
            COALESCE(p_company_name_fa, p_company_fa_name, p_company_title_fa), 
            p_company_name_en,
            p_company_about,
            p_company_url,
            NULL
        )
        ON CONFLICT (id) DO UPDATE SET
            name_fa = EXCLUDED.name_fa,
            name_en = EXCLUDED.name_en,
            about = COALESCE(EXCLUDED.about, companies.about),
            website = COALESCE(EXCLUDED.website, companies.website),
            updated_at = CURRENT_TIMESTAMP;
    END IF;

    -- Insert job into partitioned table
    INSERT INTO jobs_partitioned (
        id, title, url, locations, work_types, salary, gender, tags, 
        item_index, job_post_categories, company_fa_name, province_match_city,
        normalize_salary_min, normalize_salary_max, payment_method, district,
        company_title_fa, job_board_id, job_board_title_en, activation_time,
        company_id, company_name_fa, company_name_en, company_about, company_url,
        location_ids, tag_number, raw_data, batch_id, batch_date
    ) VALUES (
        p_id, p_title, p_url, p_locations, p_work_types, p_salary, p_gender, p_tags,
        p_item_index, p_job_post_categories, p_company_fa_name, p_province_match_city,
        p_normalize_salary_min, p_normalize_salary_max, p_payment_method, p_district,
        p_company_title_fa, p_job_board_id, p_job_board_title_en, p_activation_time,
        p_company_id, p_company_name_fa, p_company_name_en, p_company_about, p_company_url,
        p_location_ids, p_tag_number, p_raw_data, p_batch_id, p_batch_date
    )
    ON CONFLICT (id, batch_date) DO UPDATE SET
        title = EXCLUDED.title,
        url = EXCLUDED.url,
        salary = EXCLUDED.salary,
        normalize_salary_min = EXCLUDED.normalize_salary_min,
        normalize_salary_max = EXCLUDED.normalize_salary_max,
        activation_time = EXCLUDED.activation_time,
        updated_at = CURRENT_TIMESTAMP;

    -- Process tags
    IF p_tags IS NOT NULL AND jsonb_array_length(p_tags) > 0 THEN
        FOR v_tag IN SELECT * FROM jsonb_array_elements(p_tags)
        LOOP
            -- Insert the tag if it doesn't exist
            INSERT INTO job_tags (name, tag_type)
            VALUES (v_tag->>'name', v_tag->>'type')
            ON CONFLICT (name) DO UPDATE SET name = job_tags.name
            RETURNING id INTO v_tag_id;
            
            -- Link tag to job
            INSERT INTO jobs_tags (job_id, tag_id)
            VALUES (p_id, v_tag_id)
            ON CONFLICT (job_id, tag_id) DO NOTHING;
        END LOOP;
    END IF;

    -- Process categories
    IF p_job_post_categories IS NOT NULL AND jsonb_array_length(p_job_post_categories) > 0 THEN
        FOR v_category IN SELECT * FROM jsonb_array_elements(p_job_post_categories)
        LOOP
            -- Insert the category if it doesn't exist
            INSERT INTO job_categories (id, name, parent_id)
            VALUES (
                (v_category->>'id')::INTEGER, 
                v_category->>'title', 
                (v_category->>'parent_id')::INTEGER
            )
            ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name
            RETURNING id INTO v_category_id;
            
            -- Link category to job
            INSERT INTO jobs_categories (job_id, category_id)
            VALUES (p_id, v_category_id)
            ON CONFLICT (job_id, category_id) DO NOTHING;
        END LOOP;
    END IF;

    -- Process locations
    IF p_locations IS NOT NULL AND jsonb_array_length(p_locations) > 0 THEN
        FOR v_location IN SELECT * FROM jsonb_array_elements(p_locations)
        LOOP
            -- Insert the location if it doesn't exist
            INSERT INTO locations (name, province, district, location_type)
            VALUES (
                v_location->>'name',
                COALESCE(v_location->>'province', p_province_match_city),
                COALESCE(v_location->>'district', p_district),
                'city'
            )
            ON CONFLICT (name, location_type) DO UPDATE SET 
                province = COALESCE(EXCLUDED.province, locations.province),
                district = COALESCE(EXCLUDED.district, locations.district)
            RETURNING id INTO v_location_id;
            
            -- Link location to job
            INSERT INTO job_locations (job_id, location_id)
            VALUES (p_id, v_location_id)
            ON CONFLICT (job_id, location_id) DO NOTHING;
        END LOOP;
    END IF;

    -- Process work types
    IF p_work_types IS NOT NULL AND jsonb_array_length(p_work_types) > 0 THEN
        FOR v_work_type IN SELECT * FROM jsonb_array_elements(p_work_types)
        LOOP
            -- Insert the work type if it doesn't exist
            INSERT INTO work_types (name)
            VALUES (v_work_type->>'name')
            ON CONFLICT (name) DO UPDATE SET name = work_types.name
            RETURNING id INTO v_work_type_id;
            
            -- Link work type to job
            INSERT INTO job_work_types (job_id, work_type_id)
            VALUES (p_id, v_work_type_id)
            ON CONFLICT (job_id, work_type_id) DO NOTHING;
        END LOOP;
    END IF;

    RETURN p_id;
END;
$$ LANGUAGE plpgsql;

-- 3. Create a function to update job batch status
CREATE OR REPLACE FUNCTION update_job_batch(
    p_id TEXT,
    p_scraper_name TEXT,
    p_scrape_date TIMESTAMP WITHOUT TIME ZONE,
    p_status TEXT,
    p_job_count INTEGER,
    p_error_message TEXT
) RETURNS TEXT AS $$
BEGIN
    INSERT INTO job_batches_new (
        id, scraper_name, scrape_date, status, job_count, error_message
    ) VALUES (
        p_id, p_scraper_name, p_scrape_date, p_status, p_job_count, p_error_message
    )
    ON CONFLICT (id) DO UPDATE SET
        status = EXCLUDED.status,
        job_count = EXCLUDED.job_count,
        error_message = EXCLUDED.error_message,
        updated_at = CURRENT_TIMESTAMP;
        
    RETURN p_id;
END;
$$ LANGUAGE plpgsql;

-- 4. Create a function to fetch jobs with filters
CREATE OR REPLACE FUNCTION get_jobs(
    p_tag_ids INTEGER[] DEFAULT NULL,
    p_category_ids INTEGER[] DEFAULT NULL,
    p_location_ids INTEGER[] DEFAULT NULL,
    p_company_id TEXT DEFAULT NULL,
    p_min_salary DOUBLE PRECISION DEFAULT NULL,
    p_max_salary DOUBLE PRECISION DEFAULT NULL,
    p_from_date TIMESTAMP WITHOUT TIME ZONE DEFAULT NULL,
    p_to_date TIMESTAMP WITHOUT TIME ZONE DEFAULT NULL,
    p_limit INTEGER DEFAULT 100,
    p_offset INTEGER DEFAULT 0
) RETURNS TABLE (
    id TEXT,
    title TEXT,
    url TEXT,
    company_name TEXT,
    company_id TEXT,
    locations TEXT[],
    work_types TEXT[],
    tags TEXT[],
    categories TEXT[],
    min_salary DOUBLE PRECISION,
    max_salary DOUBLE PRECISION,
    activation_time TIMESTAMP WITHOUT TIME ZONE,
    batch_date TIMESTAMP WITHOUT TIME ZONE
) AS $$
BEGIN
    RETURN QUERY
    WITH filtered_jobs AS (
        SELECT 
            j.id,
            j.title,
            j.url,
            c.name_fa AS company_name,
            j.company_id,
            array_agg(DISTINCT l.name) FILTER (WHERE l.name IS NOT NULL) AS locations,
            array_agg(DISTINCT wt.name) FILTER (WHERE wt.name IS NOT NULL) AS work_types,
            array_agg(DISTINCT t.name) FILTER (WHERE t.name IS NOT NULL) AS tags,
            array_agg(DISTINCT cat.name) FILTER (WHERE cat.name IS NOT NULL) AS categories,
            j.normalize_salary_min AS min_salary,
            j.normalize_salary_max AS max_salary,
            j.activation_time,
            j.batch_date
        FROM 
            jobs_partitioned j
        LEFT JOIN 
            companies c ON j.company_id = c.id
        LEFT JOIN 
            jobs_tags jt ON j.id = jt.job_id
        LEFT JOIN 
            job_tags t ON jt.tag_id = t.id
        LEFT JOIN 
            jobs_categories jc ON j.id = jc.job_id
        LEFT JOIN 
            job_categories cat ON jc.category_id = cat.id
        LEFT JOIN 
            job_locations jl ON j.id = jl.job_id
        LEFT JOIN 
            locations l ON jl.location_id = l.id
        LEFT JOIN 
            job_work_types jwt ON j.id = jwt.job_id
        LEFT JOIN 
            work_types wt ON jwt.work_type_id = wt.id
        WHERE
            (p_tag_ids IS NULL OR jt.tag_id = ANY(p_tag_ids)) AND
            (p_category_ids IS NULL OR jc.category_id = ANY(p_category_ids)) AND
            (p_location_ids IS NULL OR jl.location_id = ANY(p_location_ids)) AND
            (p_company_id IS NULL OR j.company_id = p_company_id) AND
            (p_min_salary IS NULL OR j.normalize_salary_max >= p_min_salary) AND
            (p_max_salary IS NULL OR j.normalize_salary_min <= p_max_salary) AND
            (p_from_date IS NULL OR j.activation_time >= p_from_date) AND
            (p_to_date IS NULL OR j.activation_time <= p_to_date)
        GROUP BY 
            j.id, c.name_fa, j.company_id, j.normalize_salary_min, j.normalize_salary_max, 
            j.activation_time, j.batch_date
    )
    SELECT * FROM filtered_jobs
    ORDER BY activation_time DESC
    LIMIT p_limit OFFSET p_offset;
END;
$$ LANGUAGE plpgsql;

-- 05_modify_database_access.sql
-- Create proper database roles and permissions

-- Create application roles if they don't exist
DO $$
BEGIN
    -- Create read-only role
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'jobsdb_reader') THEN
        CREATE ROLE jobsdb_reader;
        RAISE NOTICE 'Created jobsdb_reader role';
    END IF;

    -- Create analyst role (can run analytics queries and refresh materialized views)
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'jobsdb_analyst') THEN
        CREATE ROLE jobsdb_analyst;
        RAISE NOTICE 'Created jobsdb_analyst role';
    END IF;
    
    -- Create writer role (can insert/update data)
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'jobsdb_writer') THEN
        CREATE ROLE jobsdb_writer;
        RAISE NOTICE 'Created jobsdb_writer role';
    END IF;
    
    -- Create admin role (can manage schema and all data)
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'jobsdb_admin') THEN
        CREATE ROLE jobsdb_admin;
        RAISE NOTICE 'Created jobsdb_admin role';
    END IF;
    
    -- Create application user if it doesn't exist
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'jobscraper_app') THEN
        CREATE USER jobscraper_app WITH PASSWORD 'app_password';
        RAISE NOTICE 'Created jobscraper_app user';
    END IF;
    
    -- Create analytics user if it doesn't exist
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'superset_user') THEN
        CREATE USER superset_user WITH PASSWORD 'superset_password';
        RAISE NOTICE 'Created superset_user user';
    END IF;
END $$;

-- Grant role memberships
GRANT jobsdb_reader TO jobscraper_app, superset_user;
GRANT jobsdb_analyst TO superset_user;
GRANT jobsdb_writer TO jobscraper_app;
GRANT jobsdb_admin TO jobuser;  -- Default user gets admin role

-- Grant appropriate permissions
-- Reader role permissions (SELECT only)
GRANT USAGE ON SCHEMA public TO jobsdb_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO jobsdb_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO jobsdb_reader;

-- Analyst role permissions (can refresh materialized views)
GRANT USAGE ON SCHEMA public TO jobsdb_analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO jobsdb_analyst;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO jobsdb_analyst;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO jobsdb_analyst;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO jobsdb_analyst;

-- Explicitly grant refresh permissions on materialized views
DO $$
DECLARE
    view_name text;
BEGIN
    FOR view_name IN 
        SELECT matviewname FROM pg_matviews WHERE schemaname = 'public'
    LOOP
        EXECUTE 'GRANT SELECT, REFRESH ON MATERIALIZED VIEW ' || view_name || ' TO jobsdb_analyst';
    END LOOP;
END $$;

-- Writer role permissions (insert, update, delete)
GRANT USAGE ON SCHEMA public TO jobsdb_writer;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO jobsdb_writer;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO jobsdb_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO jobsdb_writer;
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT USAGE ON SEQUENCES TO jobsdb_writer;

-- Admin role permissions (all privileges)
GRANT ALL PRIVILEGES ON SCHEMA public TO jobsdb_admin;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO jobsdb_admin;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO jobsdb_admin;
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO jobsdb_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT ALL PRIVILEGES ON TABLES TO jobsdb_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT ALL PRIVILEGES ON SEQUENCES TO jobsdb_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
    GRANT ALL PRIVILEGES ON FUNCTIONS TO jobsdb_admin;

-- Create row-level security policies
-- Enable RLS on jobs table if it exists
DO $$
BEGIN
    IF EXISTS (
        SELECT FROM information_schema.tables 
        WHERE table_schema = 'public' AND table_name = 'jobs'
    ) THEN
        -- Enable row-level security
        ALTER TABLE jobs ENABLE ROW LEVEL SECURITY;
        
        -- Create policies
        DROP POLICY IF EXISTS jobs_all_access ON jobs;
        CREATE POLICY jobs_all_access ON jobs TO jobsdb_admin USING (true);
        
        DROP POLICY IF EXISTS jobs_read_access ON jobs;
        CREATE POLICY jobs_read_access ON jobs FOR SELECT TO jobsdb_reader USING (true);
        
        DROP POLICY IF EXISTS jobs_write_access ON jobs;
        CREATE POLICY jobs_write_access ON jobs FOR INSERT TO jobsdb_writer WITH CHECK (true);
        
        DROP POLICY IF EXISTS jobs_update_access ON jobs;
        CREATE POLICY jobs_update_access ON jobs FOR UPDATE TO jobsdb_writer USING (true) WITH CHECK (true);
        
        RAISE NOTICE 'Enabled row-level security on jobs table';
    END IF;
    
    -- Also enable RLS on partitioned jobs table if it exists
    IF EXISTS (
        SELECT FROM information_schema.tables 
        WHERE table_schema = 'public' AND table_name = 'jobs_partitioned'
    ) THEN
        -- Enable row-level security
        ALTER TABLE jobs_partitioned ENABLE ROW LEVEL SECURITY;
        
        -- Create policies
        DROP POLICY IF EXISTS jobs_partitioned_all_access ON jobs_partitioned;
        CREATE POLICY jobs_partitioned_all_access ON jobs_partitioned TO jobsdb_admin USING (true);
        
        DROP POLICY IF EXISTS jobs_partitioned_read_access ON jobs_partitioned;
        CREATE POLICY jobs_partitioned_read_access ON jobs_partitioned FOR SELECT TO jobsdb_reader USING (true);
        
        DROP POLICY IF EXISTS jobs_partitioned_write_access ON jobs_partitioned;
        CREATE POLICY jobs_partitioned_write_access ON jobs_partitioned FOR INSERT TO jobsdb_writer WITH CHECK (true);
        
        DROP POLICY IF EXISTS jobs_partitioned_update_access ON jobs_partitioned;
        CREATE POLICY jobs_partitioned_update_access ON jobs_partitioned FOR UPDATE TO jobsdb_writer USING (true) WITH CHECK (true);
        
        RAISE NOTICE 'Enabled row-level security on jobs_partitioned table';
    END IF;
END $$;

-- Create performance-related indexes
DO $$
BEGIN
    RAISE NOTICE 'Creating additional performance indexes...';
    
    -- Full-text search index if tsvector extension is available
    IF EXISTS (
        SELECT 1 
        FROM pg_extension 
        WHERE extname = 'pg_trgm'
    ) THEN
        -- Create GIN indexes for text search on jobs table if it exists
        IF EXISTS (
            SELECT FROM information_schema.tables 
            WHERE table_schema = 'public' AND table_name = 'jobs'
        ) THEN
            CREATE INDEX IF NOT EXISTS idx_jobs_title_trgm ON jobs USING GIN (title gin_trgm_ops);
            CREATE INDEX IF NOT EXISTS idx_jobs_description_trgm ON jobs USING GIN (description gin_trgm_ops);
            RAISE NOTICE 'Created text search indexes on jobs table';
        END IF;
        
        -- Also create indexes on companies table
        CREATE INDEX IF NOT EXISTS idx_companies_name_trgm ON companies USING GIN (name gin_trgm_ops);
        RAISE NOTICE 'Created text search indexes on companies table';
    ELSE
        RAISE NOTICE 'pg_trgm extension not available. Skipping full-text search index creation.';
    END IF;
END $$;

-- Set some reasonable vacuum and autovacuum settings
ALTER TABLE companies SET (
    autovacuum_vacuum_scale_factor = 0.1,
    autovacuum_analyze_scale_factor = 0.05
);

ALTER TABLE job_tags SET (
    autovacuum_vacuum_scale_factor = 0.1,
    autovacuum_analyze_scale_factor = 0.05
);

ALTER TABLE job_categories SET (
    autovacuum_vacuum_scale_factor = 0.1,
    autovacuum_analyze_scale_factor = 0.05
);

RAISE NOTICE 'Database access controls and optimizations completed.'; 