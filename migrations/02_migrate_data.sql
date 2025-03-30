-- Script to migrate data from original tables to normalized tables

-- 1. Migrate Companies Data
INSERT INTO companies (id, name_fa, name_en, title_fa, about, url, created_at, updated_at)
SELECT DISTINCT 
    company_id, 
    company_name_fa, 
    company_name_en, 
    company_title_fa, 
    company_about, 
    company_url, 
    CURRENT_TIMESTAMP, 
    CURRENT_TIMESTAMP
FROM jobs
WHERE company_id IS NOT NULL
ON CONFLICT (id) DO UPDATE SET
    name_fa = EXCLUDED.name_fa,
    name_en = EXCLUDED.name_en,
    title_fa = EXCLUDED.title_fa,
    about = EXCLUDED.about,
    url = EXCLUDED.url,
    updated_at = CURRENT_TIMESTAMP;

-- 2. Extract and Migrate Tags
INSERT INTO job_tags (name_fa, tag_type)
SELECT DISTINCT 
    jsonb_array_elements_text(tags) as tag_name,
    CASE 
        WHEN jsonb_array_elements_text(tags) IN ('پاره وقت', 'تمام وقت', 'پروژه ای') THEN 'schedule'
        WHEN jsonb_array_elements_text(tags) IN ('دورکاری', 'کارآموزی', 'بدون نیاز به سابقه') THEN 'work_arrangement'
        ELSE 'other'
    END as tag_type
FROM jobs
WHERE jsonb_typeof(tags) = 'array' AND jsonb_array_length(tags) > 0
ON CONFLICT (name_fa) DO NOTHING;

-- Link tags to jobs
INSERT INTO jobs_tags (job_id, tag_id)
SELECT DISTINCT j.id, t.id
FROM jobs j
CROSS JOIN LATERAL jsonb_array_elements_text(j.tags) as tag_value
JOIN job_tags t ON tag_value = t.name_fa
WHERE jsonb_typeof(j.tags) = 'array' AND jsonb_array_length(j.tags) > 0
ON CONFLICT (job_id, tag_id) DO NOTHING;

-- 3. Extract and Migrate Categories
-- First extract top-level categories
WITH categories AS (
    SELECT DISTINCT 
        (jsonb_array_elements(job_post_categories)->>'id')::integer as id,
        jsonb_array_elements(job_post_categories)->>'titleFa' as name_fa,
        jsonb_array_elements(job_post_categories)->>'titleEn' as name_en,
        (jsonb_array_elements(job_post_categories)->>'parentId')::integer as parent_id,
        jsonb_array_elements(job_post_categories)->>'urlParameter' as url_parameter,
        (jsonb_array_elements(job_post_categories)->>'seoOrder')::integer as seo_order
    FROM jobs
    WHERE jsonb_typeof(job_post_categories) = 'array'
)
INSERT INTO job_categories (id, name_fa, name_en, parent_id, url_parameter, seo_order)
SELECT 
    id, 
    name_fa, 
    name_en, 
    parent_id, 
    url_parameter, 
    seo_order
FROM categories
ON CONFLICT (id) DO UPDATE SET
    name_fa = EXCLUDED.name_fa,
    name_en = EXCLUDED.name_en,
    parent_id = EXCLUDED.parent_id,
    url_parameter = EXCLUDED.url_parameter,
    seo_order = EXCLUDED.seo_order;

-- Link categories to jobs
INSERT INTO jobs_categories (job_id, category_id, position)
SELECT 
    j.id, 
    (jsonb_array_elements(j.job_post_categories)->>'id')::integer as category_id,
    row_number() OVER (PARTITION BY j.id ORDER BY (jsonb_array_elements(j.job_post_categories)->>'id')::integer) as position
FROM jobs j
WHERE jsonb_typeof(j.job_post_categories) = 'array'
ON CONFLICT (job_id, category_id) DO NOTHING;

-- 4. Extract and Migrate Locations
-- Insert locations that exist in the locations JSONB
WITH location_data AS (
    SELECT DISTINCT 
        (jsonb_array_elements(locations)->>'id')::integer as id,
        jsonb_array_elements(locations)->>'city' as name_fa,
        NULL::text as name_en,
        NULL::integer as parent_id,
        'city' as location_type
    FROM jobs
    WHERE jsonb_typeof(locations) = 'array' 
    AND jsonb_array_length(locations) > 0
    AND jsonb_array_elements(locations)->>'id' IS NOT NULL
),
province_data AS (
    SELECT DISTINCT
        province_match_city as name_fa,
        NULL::text as name_en,
        NULL::integer as parent_id,
        'province' as location_type
    FROM jobs
    WHERE province_match_city IS NOT NULL
    AND province_match_city != ''
),
district_data AS (
    SELECT DISTINCT
        district as name_fa,
        NULL::text as name_en,
        NULL::integer as parent_id,
        'district' as location_type
    FROM jobs
    WHERE district IS NOT NULL
    AND district != ''
)
INSERT INTO locations (name_fa, name_en, parent_id, location_type)
SELECT name_fa, name_en, parent_id, location_type
FROM (
    SELECT name_fa, name_en, parent_id, location_type FROM location_data
    UNION
    SELECT name_fa, name_en, parent_id, location_type FROM province_data
    UNION
    SELECT name_fa, name_en, parent_id, location_type FROM district_data
) as all_locations
WHERE name_fa IS NOT NULL
ON CONFLICT DO NOTHING;

-- Link locations to jobs (this is a bit more complex and would need to be refined)
INSERT INTO job_locations (job_id, location_id)
SELECT DISTINCT j.id, l.id
FROM jobs j
JOIN locations l ON 
    (j.province_match_city IS NOT NULL AND j.province_match_city = l.name_fa) OR
    (j.district IS NOT NULL AND j.district = l.name_fa)
ON CONFLICT (job_id, location_id) DO NOTHING;

-- 5. Extract and Migrate Work Types
INSERT INTO work_types (name_fa, name_en)
SELECT DISTINCT 
    jsonb_array_elements_text(work_types) as name_fa,
    NULL as name_en
FROM jobs
WHERE jsonb_typeof(work_types) = 'array' AND jsonb_array_length(work_types) > 0
ON CONFLICT (name_fa) DO NOTHING;

-- Link work types to jobs
INSERT INTO job_work_types (job_id, work_type_id)
SELECT DISTINCT j.id, w.id
FROM jobs j
CROSS JOIN LATERAL jsonb_array_elements_text(j.work_types) as work_type_value
JOIN work_types w ON work_type_value = w.name_fa
WHERE jsonb_typeof(j.work_types) = 'array' AND jsonb_array_length(j.work_types) > 0
ON CONFLICT (job_id, work_type_id) DO NOTHING;

-- 6. Migrate Job Batches Data (if needed)
INSERT INTO job_batches_new (batch_id, batch_date, job_count, source, processing_time, status, error_message, created_at, completed_at)
SELECT 
    batch_id, 
    batch_date, 
    job_count, 
    source, 
    processing_time, 
    status, 
    error_message, 
    created_at, 
    completed_at
FROM job_batches
ON CONFLICT (batch_id) DO UPDATE SET
    batch_date = EXCLUDED.batch_date,
    job_count = EXCLUDED.job_count,
    source = EXCLUDED.source,
    processing_time = EXCLUDED.processing_time,
    status = EXCLUDED.status,
    error_message = EXCLUDED.error_message,
    completed_at = EXCLUDED.completed_at;

-- 7. Also migrate to partitioned table
INSERT INTO job_batches_partitioned (batch_date, source, job_count, status, started_at, completed_at, notes)
SELECT 
    batch_date,
    source,
    job_count,
    status,
    started_at,
    completed_at,
    notes
FROM job_batches_new
ON CONFLICT DO NOTHING; 