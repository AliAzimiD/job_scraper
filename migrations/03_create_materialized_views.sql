-- Script to create materialized views for analytics

-- 1. Job Statistics by Company
CREATE MATERIALIZED VIEW IF NOT EXISTS job_stats_by_company AS
SELECT 
    c.id as company_id,
    c.name_fa as company_name,
    COUNT(j.id) as job_count,
    AVG(j.normalize_salary_min) as avg_min_salary,
    AVG(j.normalize_salary_max) as avg_max_salary,
    MIN(j.activation_time) as first_job_date,
    MAX(j.activation_time) as latest_job_date
FROM 
    companies c
    JOIN jobs j ON c.id = j.company_id
GROUP BY 
    c.id, c.name_fa;

-- Create index on company_id for the materialized view
CREATE UNIQUE INDEX IF NOT EXISTS idx_job_stats_by_company_id ON job_stats_by_company(company_id);

-- 2. Job Statistics by Tag
CREATE MATERIALIZED VIEW IF NOT EXISTS job_stats_by_tag AS
SELECT 
    t.id as tag_id,
    t.name_fa as tag_name,
    t.tag_type,
    COUNT(j.id) as job_count,
    ROUND(AVG(j.normalize_salary_min)) as avg_min_salary,
    ROUND(AVG(j.normalize_salary_max)) as avg_max_salary,
    MIN(j.activation_time) as first_job_date,
    MAX(j.activation_time) as latest_job_date
FROM 
    job_tags t
    JOIN jobs_tags jt ON t.id = jt.tag_id
    JOIN jobs j ON jt.job_id = j.id
GROUP BY 
    t.id, t.name_fa, t.tag_type;

-- Create index on tag_id for the materialized view
CREATE UNIQUE INDEX IF NOT EXISTS idx_job_stats_by_tag_id ON job_stats_by_tag(tag_id);

-- 3. Job Statistics by Category
CREATE MATERIALIZED VIEW IF NOT EXISTS job_stats_by_category AS
SELECT 
    c.id as category_id,
    c.name_fa as category_name,
    c.parent_id,
    COUNT(j.id) as job_count,
    ROUND(AVG(j.normalize_salary_min)) as avg_min_salary,
    ROUND(AVG(j.normalize_salary_max)) as avg_max_salary,
    MIN(j.activation_time) as first_job_date,
    MAX(j.activation_time) as latest_job_date
FROM 
    job_categories c
    JOIN jobs_categories jc ON c.id = jc.category_id
    JOIN jobs j ON jc.job_id = j.id
GROUP BY 
    c.id, c.name_fa, c.parent_id;

-- Create index on category_id for the materialized view
CREATE UNIQUE INDEX IF NOT EXISTS idx_job_stats_by_category_id ON job_stats_by_category(category_id);

-- 4. Job Statistics by Location
CREATE MATERIALIZED VIEW IF NOT EXISTS job_stats_by_location AS
SELECT 
    l.id as location_id,
    l.name_fa as location_name,
    l.location_type,
    COUNT(j.id) as job_count,
    ROUND(AVG(j.normalize_salary_min)) as avg_min_salary,
    ROUND(AVG(j.normalize_salary_max)) as avg_max_salary,
    MIN(j.activation_time) as first_job_date,
    MAX(j.activation_time) as latest_job_date
FROM 
    locations l
    JOIN job_locations jl ON l.id = jl.location_id
    JOIN jobs j ON jl.job_id = j.id
GROUP BY 
    l.id, l.name_fa, l.location_type;

-- Create index on location_id for the materialized view
CREATE UNIQUE INDEX IF NOT EXISTS idx_job_stats_by_location_id ON job_stats_by_location(location_id);

-- 5. Tag Co-occurrence (which tags appear together)
CREATE MATERIALIZED VIEW IF NOT EXISTS tag_cooccurrence AS
SELECT 
    t1.id as tag1_id, 
    t1.name_fa as tag1_name,
    t2.id as tag2_id,
    t2.name_fa as tag2_name,
    COUNT(*) as frequency
FROM 
    jobs_tags jt1
    JOIN jobs_tags jt2 ON jt1.job_id = jt2.job_id AND jt1.tag_id < jt2.tag_id
    JOIN job_tags t1 ON jt1.tag_id = t1.id
    JOIN job_tags t2 ON jt2.tag_id = t2.id
GROUP BY 
    t1.id, t1.name_fa, t2.id, t2.name_fa
HAVING 
    COUNT(*) > 10;

-- Create compound index on tag IDs for the materialized view
CREATE UNIQUE INDEX IF NOT EXISTS idx_tag_cooccurrence_tag_ids ON tag_cooccurrence(tag1_id, tag2_id);

-- 6. Category/Tag Relationship
CREATE MATERIALIZED VIEW IF NOT EXISTS category_tag_relationship AS
SELECT 
    c.id as category_id,
    c.name_fa as category_name,
    t.id as tag_id,
    t.name_fa as tag_name,
    COUNT(*) as frequency
FROM 
    jobs_categories jc
    JOIN jobs_tags jt ON jc.job_id = jt.job_id
    JOIN job_categories c ON jc.category_id = c.id
    JOIN job_tags t ON jt.tag_id = t.id
GROUP BY 
    c.id, c.name_fa, t.id, t.name_fa
HAVING 
    COUNT(*) > 10;

-- Create compound index on category and tag IDs for the materialized view
CREATE UNIQUE INDEX IF NOT EXISTS idx_category_tag_relationship_ids ON category_tag_relationship(category_id, tag_id);

-- 7. Job Posting Trends (time series data)
CREATE MATERIALIZED VIEW IF NOT EXISTS job_posting_trends AS
SELECT 
    DATE_TRUNC('day', activation_time) as post_date,
    COUNT(*) as job_count,
    ROUND(AVG(normalize_salary_min)) as avg_min_salary,
    ROUND(AVG(normalize_salary_max)) as avg_max_salary
FROM 
    jobs
WHERE 
    activation_time IS NOT NULL
GROUP BY 
    DATE_TRUNC('day', activation_time)
ORDER BY 
    post_date;

-- Create index on post_date for the materialized view
CREATE UNIQUE INDEX IF NOT EXISTS idx_job_posting_trends_date ON job_posting_trends(post_date);

-- 8. Function to refresh all materialized views
CREATE OR REPLACE FUNCTION refresh_all_job_materialized_views()
RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW job_stats_by_company;
    REFRESH MATERIALIZED VIEW job_stats_by_tag;
    REFRESH MATERIALIZED VIEW job_stats_by_category;
    REFRESH MATERIALIZED VIEW job_stats_by_location;
    REFRESH MATERIALIZED VIEW tag_cooccurrence;
    REFRESH MATERIALIZED VIEW category_tag_relationship;
    REFRESH MATERIALIZED VIEW job_posting_trends;
END;
$$ LANGUAGE plpgsql;

-- Create materialized view for job stats by company
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_job_stats_by_company AS
SELECT 
    c.id AS company_id,
    c.name AS company_name,
    c.url AS company_url,
    c.logo_url AS company_logo,
    COUNT(DISTINCT j.id) AS job_count,
    MAX(j.created_at) AS last_job_posted,
    MIN(j.created_at) AS first_job_posted,
    COUNT(DISTINCT j.job_batch_id) AS batch_count,
    array_agg(DISTINCT wt.name) AS work_types,
    array_agg(DISTINCT l.name) AS locations
FROM 
    companies c
    LEFT JOIN jobs j ON c.id = j.company_id
    LEFT JOIN job_work_types jwt ON j.id = jwt.job_id
    LEFT JOIN work_types wt ON jwt.work_type_id = wt.id
    LEFT JOIN job_locations jl ON j.id = jl.job_id
    LEFT JOIN locations l ON jl.location_id = l.id
GROUP BY 
    c.id, c.name, c.url, c.logo_url
WITH NO DATA;

-- Refresh the job stats by company materialized view
REFRESH MATERIALIZED VIEW mv_job_stats_by_company;

-- Create index on the materialized view
CREATE INDEX IF NOT EXISTS idx_mv_job_stats_by_company_job_count 
ON mv_job_stats_by_company (job_count DESC);
CREATE INDEX IF NOT EXISTS idx_mv_job_stats_by_company_name 
ON mv_job_stats_by_company (company_name);

-- Create materialized view for job stats by tag
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_job_stats_by_tag AS
SELECT 
    t.id AS tag_id,
    t.name AS tag_name,
    COUNT(DISTINCT j.id) AS job_count,
    COUNT(DISTINCT j.company_id) AS company_count,
    MAX(j.created_at) AS last_job_posted,
    MIN(j.created_at) AS first_job_posted,
    EXTRACT(MONTH FROM j.created_at) AS month,
    EXTRACT(YEAR FROM j.created_at) AS year
FROM 
    job_tags t
    JOIN jobs_tags jt ON t.id = jt.tag_id
    JOIN jobs j ON jt.job_id = j.id
GROUP BY 
    t.id, t.name, EXTRACT(MONTH FROM j.created_at), EXTRACT(YEAR FROM j.created_at)
WITH NO DATA;

-- Refresh the job stats by tag materialized view
REFRESH MATERIALIZED VIEW mv_job_stats_by_tag;

-- Create index on the materialized view
CREATE INDEX IF NOT EXISTS idx_mv_job_stats_by_tag_job_count 
ON mv_job_stats_by_tag (job_count DESC);
CREATE INDEX IF NOT EXISTS idx_mv_job_stats_by_tag_name 
ON mv_job_stats_by_tag (tag_name);

-- Create materialized view for job stats by category
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_job_stats_by_category AS
SELECT 
    c.id AS category_id,
    c.name AS category_name,
    COUNT(DISTINCT j.id) AS job_count,
    COUNT(DISTINCT j.company_id) AS company_count,
    MAX(j.created_at) AS last_job_posted,
    MIN(j.created_at) AS first_job_posted,
    EXTRACT(MONTH FROM j.created_at) AS month,
    EXTRACT(YEAR FROM j.created_at) AS year
FROM 
    job_categories c
    JOIN jobs_categories jc ON c.id = jc.category_id
    JOIN jobs j ON jc.job_id = j.id
GROUP BY 
    c.id, c.name, EXTRACT(MONTH FROM j.created_at), EXTRACT(YEAR FROM j.created_at)
WITH NO DATA;

-- Refresh the job stats by category materialized view
REFRESH MATERIALIZED VIEW mv_job_stats_by_category;

-- Create index on the materialized view
CREATE INDEX IF NOT EXISTS idx_mv_job_stats_by_category_job_count 
ON mv_job_stats_by_category (job_count DESC);
CREATE INDEX IF NOT EXISTS idx_mv_job_stats_by_category_name 
ON mv_job_stats_by_category (category_name);

-- Create materialized view for job stats by location
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_job_stats_by_location AS
SELECT 
    l.id AS location_id,
    l.name AS location_name,
    l.is_remote,
    COUNT(DISTINCT j.id) AS job_count,
    COUNT(DISTINCT j.company_id) AS company_count,
    MAX(j.created_at) AS last_job_posted,
    MIN(j.created_at) AS first_job_posted,
    EXTRACT(MONTH FROM j.created_at) AS month,
    EXTRACT(YEAR FROM j.created_at) AS year
FROM 
    locations l
    JOIN job_locations jl ON l.id = jl.location_id
    JOIN jobs j ON jl.job_id = j.id
GROUP BY 
    l.id, l.name, l.is_remote, EXTRACT(MONTH FROM j.created_at), EXTRACT(YEAR FROM j.created_at)
WITH NO DATA;

-- Refresh the job stats by location materialized view
REFRESH MATERIALIZED VIEW mv_job_stats_by_location;

-- Create index on the materialized view
CREATE INDEX IF NOT EXISTS idx_mv_job_stats_by_location_job_count 
ON mv_job_stats_by_location (job_count DESC);
CREATE INDEX IF NOT EXISTS idx_mv_job_stats_by_location_name 
ON mv_job_stats_by_location (location_name);

-- Create materialized view for tag co-occurrence
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_tag_co_occurrence AS
SELECT 
    t1.id AS tag1_id,
    t1.name AS tag1_name,
    t2.id AS tag2_id,
    t2.name AS tag2_name,
    COUNT(DISTINCT j1.job_id) AS co_occurrence_count
FROM 
    jobs_tags j1
    JOIN jobs_tags j2 ON j1.job_id = j2.job_id AND j1.tag_id < j2.tag_id
    JOIN job_tags t1 ON j1.tag_id = t1.id
    JOIN job_tags t2 ON j2.tag_id = t2.id
GROUP BY 
    t1.id, t1.name, t2.id, t2.name
WITH NO DATA;

-- Refresh the tag co-occurrence materialized view
REFRESH MATERIALIZED VIEW mv_tag_co_occurrence;

-- Create index on the materialized view
CREATE INDEX IF NOT EXISTS idx_mv_tag_co_occurrence_count 
ON mv_tag_co_occurrence (co_occurrence_count DESC);

-- Create materialized view for category and tag relationship
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_category_tag_relationship AS
SELECT 
    c.id AS category_id,
    c.name AS category_name,
    t.id AS tag_id,
    t.name AS tag_name,
    COUNT(DISTINCT jc.job_id) AS job_count
FROM 
    jobs_categories jc
    JOIN jobs_tags jt ON jc.job_id = jt.job_id
    JOIN job_categories c ON jc.category_id = c.id
    JOIN job_tags t ON jt.tag_id = t.id
GROUP BY 
    c.id, c.name, t.id, t.name
WITH NO DATA;

-- Refresh the category tag relationship materialized view
REFRESH MATERIALIZED VIEW mv_category_tag_relationship;

-- Create index on the materialized view
CREATE INDEX IF NOT EXISTS idx_mv_category_tag_relationship_job_count 
ON mv_category_tag_relationship (job_count DESC);

-- Create materialized view for job posting trends
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_job_posting_trends AS
SELECT 
    DATE_TRUNC('day', j.created_at) AS posting_date,
    COUNT(j.id) AS daily_job_count,
    COUNT(DISTINCT j.company_id) AS daily_company_count,
    array_agg(DISTINCT t.name) FILTER (WHERE t.name IS NOT NULL) AS top_tags,
    array_agg(DISTINCT c.name) FILTER (WHERE c.name IS NOT NULL) AS top_categories
FROM 
    jobs j
    LEFT JOIN jobs_tags jt ON j.id = jt.job_id
    LEFT JOIN job_tags t ON jt.tag_id = t.id
    LEFT JOIN jobs_categories jc ON j.id = jc.job_id
    LEFT JOIN job_categories c ON jc.category_id = c.id
GROUP BY 
    DATE_TRUNC('day', j.created_at)
WITH NO DATA;

-- Refresh the job posting trends materialized view
REFRESH MATERIALIZED VIEW mv_job_posting_trends;

-- Create index on the materialized view
CREATE INDEX IF NOT EXISTS idx_mv_job_posting_trends_date 
ON mv_job_posting_trends (posting_date DESC);

-- Create a function to refresh all materialized views
CREATE OR REPLACE FUNCTION refresh_all_materialized_views() RETURNS void AS $$
DECLARE
    view_name text;
BEGIN
    FOR view_name IN 
        SELECT matviewname FROM pg_matviews WHERE schemaname = 'public'
    LOOP
        EXECUTE 'REFRESH MATERIALIZED VIEW ' || view_name;
    END LOOP;
END;
$$ LANGUAGE plpgsql; 