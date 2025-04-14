--
-- PostgreSQL database dump
--

-- Dumped from database version 15.12
-- Dumped by pg_dump version 15.12

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: emaildeliverytype; Type: TYPE; Schema: public; Owner: jobuser
--

CREATE TYPE public.emaildeliverytype AS ENUM (
    'attachment',
    'inline'
);


ALTER TYPE public.emaildeliverytype OWNER TO jobuser;

--
-- Name: objecttype; Type: TYPE; Schema: public; Owner: jobuser
--

CREATE TYPE public.objecttype AS ENUM (
    'query',
    'chart',
    'dashboard',
    'dataset'
);


ALTER TYPE public.objecttype OWNER TO jobuser;

--
-- Name: sliceemailreportformat; Type: TYPE; Schema: public; Owner: jobuser
--

CREATE TYPE public.sliceemailreportformat AS ENUM (
    'visualization',
    'data'
);


ALTER TYPE public.sliceemailreportformat OWNER TO jobuser;

--
-- Name: tagtype; Type: TYPE; Schema: public; Owner: jobuser
--

CREATE TYPE public.tagtype AS ENUM (
    'custom',
    'type',
    'owner',
    'favorited_by'
);


ALTER TYPE public.tagtype OWNER TO jobuser;

--
-- Name: create_future_job_partitions(integer); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.create_future_job_partitions(years_ahead integer DEFAULT 1) RETURNS void
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.create_future_job_partitions(years_ahead integer) OWNER TO jobuser;

--
-- Name: create_job_partitions(integer, integer); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.create_job_partitions(p_start_year integer, p_end_year integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.create_job_partitions(p_start_year integer, p_end_year integer) OWNER TO jobuser;

--
-- Name: create_new_partition_trigger(); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.create_new_partition_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.create_new_partition_trigger() OWNER TO jobuser;

--
-- Name: get_jobs(integer[], integer[], integer[], text, double precision, double precision, timestamp without time zone, timestamp without time zone, integer, integer); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.get_jobs(p_tag_ids integer[] DEFAULT NULL::integer[], p_category_ids integer[] DEFAULT NULL::integer[], p_location_ids integer[] DEFAULT NULL::integer[], p_company_id text DEFAULT NULL::text, p_min_salary double precision DEFAULT NULL::double precision, p_max_salary double precision DEFAULT NULL::double precision, p_from_date timestamp without time zone DEFAULT NULL::timestamp without time zone, p_to_date timestamp without time zone DEFAULT NULL::timestamp without time zone, p_limit integer DEFAULT 100, p_offset integer DEFAULT 0) RETURNS TABLE(id text, title text, url text, company_name text, company_id text, locations text[], work_types text[], tags text[], categories text[], min_salary double precision, max_salary double precision, activation_time timestamp without time zone, batch_date timestamp without time zone)
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.get_jobs(p_tag_ids integer[], p_category_ids integer[], p_location_ids integer[], p_company_id text, p_min_salary double precision, p_max_salary double precision, p_from_date timestamp without time zone, p_to_date timestamp without time zone, p_limit integer, p_offset integer) OWNER TO jobuser;

--
-- Name: health_check(); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.health_check() RETURNS text
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN 'OK';
END;
$$;


ALTER FUNCTION public.health_check() OWNER TO jobuser;

--
-- Name: insert_job(text, text, text, jsonb, jsonb, jsonb, text, jsonb, integer, jsonb, text, text, double precision, double precision, text, text, text, text, text, timestamp without time zone, text, text, text, text, text, text, text, jsonb, text, timestamp without time zone); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.insert_job(p_id text, p_title text, p_url text, p_locations jsonb, p_work_types jsonb, p_salary jsonb, p_gender text, p_tags jsonb, p_item_index integer, p_job_post_categories jsonb, p_company_fa_name text, p_province_match_city text, p_normalize_salary_min double precision, p_normalize_salary_max double precision, p_payment_method text, p_district text, p_company_title_fa text, p_job_board_id text, p_job_board_title_en text, p_activation_time timestamp without time zone, p_company_id text, p_company_name_fa text, p_company_name_en text, p_company_about text, p_company_url text, p_location_ids text, p_tag_number text, p_raw_data jsonb, p_batch_id text, p_batch_date timestamp without time zone) RETURNS text
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.insert_job(p_id text, p_title text, p_url text, p_locations jsonb, p_work_types jsonb, p_salary jsonb, p_gender text, p_tags jsonb, p_item_index integer, p_job_post_categories jsonb, p_company_fa_name text, p_province_match_city text, p_normalize_salary_min double precision, p_normalize_salary_max double precision, p_payment_method text, p_district text, p_company_title_fa text, p_job_board_id text, p_job_board_title_en text, p_activation_time timestamp without time zone, p_company_id text, p_company_name_fa text, p_company_name_en text, p_company_about text, p_company_url text, p_location_ids text, p_tag_number text, p_raw_data jsonb, p_batch_id text, p_batch_date timestamp without time zone) OWNER TO jobuser;

--
-- Name: insert_or_update_job(text, text, text, text, text, boolean, text, numeric, numeric, text, text, text, date, text[], text[]); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.insert_or_update_job(p_title text, p_description text, p_company_name text, p_company_url text, p_location_name text, p_is_remote boolean, p_work_type_name text, p_salary_min numeric, p_salary_max numeric, p_currency text, p_url text, p_source text, p_batch_date date, p_tags text[], p_categories text[]) RETURNS integer
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.insert_or_update_job(p_title text, p_description text, p_company_name text, p_company_url text, p_location_name text, p_is_remote boolean, p_work_type_name text, p_salary_min numeric, p_salary_max numeric, p_currency text, p_url text, p_source text, p_batch_date date, p_tags text[], p_categories text[]) OWNER TO jobuser;

--
-- Name: jobs_view_delete_trigger(); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.jobs_view_delete_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    DELETE FROM jobs_partitioned WHERE id = OLD.id;
    RETURN OLD;
END;
$$;


ALTER FUNCTION public.jobs_view_delete_trigger() OWNER TO jobuser;

--
-- Name: jobs_view_insert_trigger(); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.jobs_view_insert_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    INSERT INTO jobs_partitioned VALUES (NEW.*);
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.jobs_view_insert_trigger() OWNER TO jobuser;

--
-- Name: jobs_view_update_trigger(); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.jobs_view_update_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.jobs_view_update_trigger() OWNER TO jobuser;

--
-- Name: maintain_partitions(); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.maintain_partitions() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM run_maintenance(p_analyze := false);
END;
$$;


ALTER FUNCTION public.maintain_partitions() OWNER TO jobuser;

--
-- Name: FUNCTION maintain_partitions(); Type: COMMENT; Schema: public; Owner: jobuser
--

COMMENT ON FUNCTION public.maintain_partitions() IS 'This function should be scheduled to run daily using a cron job:
Example: 
0 0 * * * psql -U postgres -d jobsdb -c "SELECT maintain_partitions();"';


--
-- Name: migrate_to_partitioned_jobs(); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.migrate_to_partitioned_jobs() RETURNS integer
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.migrate_to_partitioned_jobs() OWNER TO jobuser;

--
-- Name: refresh_all_job_materialized_views(); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.refresh_all_job_materialized_views() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    REFRESH MATERIALIZED VIEW job_stats_by_company;
    REFRESH MATERIALIZED VIEW job_stats_by_tag;
    REFRESH MATERIALIZED VIEW job_stats_by_category;
    REFRESH MATERIALIZED VIEW job_stats_by_location;
    REFRESH MATERIALIZED VIEW tag_cooccurrence;
    REFRESH MATERIALIZED VIEW category_tag_relationship;
    REFRESH MATERIALIZED VIEW job_posting_trends;
END;
$$;


ALTER FUNCTION public.refresh_all_job_materialized_views() OWNER TO jobuser;

--
-- Name: refresh_all_materialized_views(); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.refresh_all_materialized_views() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    view_name text;
BEGIN
    FOR view_name IN 
        SELECT matviewname FROM pg_matviews WHERE schemaname = 'public'
    LOOP
        EXECUTE 'REFRESH MATERIALIZED VIEW ' || view_name;
    END LOOP;
END;
$$;


ALTER FUNCTION public.refresh_all_materialized_views() OWNER TO jobuser;

--
-- Name: update_job_batch(text, text, timestamp without time zone, text, integer, text); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.update_job_batch(p_id text, p_scraper_name text, p_scrape_date timestamp without time zone, p_status text, p_job_count integer, p_error_message text) RETURNS text
    LANGUAGE plpgsql
    AS $$
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
$$;


ALTER FUNCTION public.update_job_batch(p_id text, p_scraper_name text, p_scrape_date timestamp without time zone, p_status text, p_job_count integer, p_error_message text) OWNER TO jobuser;

--
-- Name: update_updated_at_column(); Type: FUNCTION; Schema: public; Owner: jobuser
--

CREATE FUNCTION public.update_updated_at_column() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$;


ALTER FUNCTION public.update_updated_at_column() OWNER TO jobuser;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: ab_permission; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.ab_permission (
    id integer NOT NULL,
    name character varying(100) NOT NULL
);


ALTER TABLE public.ab_permission OWNER TO jobuser;

--
-- Name: ab_permission_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.ab_permission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.ab_permission_id_seq OWNER TO jobuser;

--
-- Name: ab_permission_view; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.ab_permission_view (
    id integer NOT NULL,
    permission_id integer,
    view_menu_id integer
);


ALTER TABLE public.ab_permission_view OWNER TO jobuser;

--
-- Name: ab_permission_view_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.ab_permission_view_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.ab_permission_view_id_seq OWNER TO jobuser;

--
-- Name: ab_permission_view_role; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.ab_permission_view_role (
    id integer NOT NULL,
    permission_view_id integer,
    role_id integer
);


ALTER TABLE public.ab_permission_view_role OWNER TO jobuser;

--
-- Name: ab_permission_view_role_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.ab_permission_view_role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.ab_permission_view_role_id_seq OWNER TO jobuser;

--
-- Name: ab_register_user; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.ab_register_user (
    id integer NOT NULL,
    first_name character varying(64) NOT NULL,
    last_name character varying(64) NOT NULL,
    username character varying(64) NOT NULL,
    password character varying(256),
    email character varying(64) NOT NULL,
    registration_date timestamp without time zone,
    registration_hash character varying(256)
);


ALTER TABLE public.ab_register_user OWNER TO jobuser;

--
-- Name: ab_register_user_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.ab_register_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.ab_register_user_id_seq OWNER TO jobuser;

--
-- Name: ab_role; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.ab_role (
    id integer NOT NULL,
    name character varying(64) NOT NULL
);


ALTER TABLE public.ab_role OWNER TO jobuser;

--
-- Name: ab_role_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.ab_role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.ab_role_id_seq OWNER TO jobuser;

--
-- Name: ab_user; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.ab_user (
    id integer NOT NULL,
    first_name character varying(64) NOT NULL,
    last_name character varying(64) NOT NULL,
    username character varying(64) NOT NULL,
    password character varying(256),
    active boolean,
    email character varying(320) NOT NULL,
    last_login timestamp without time zone,
    login_count integer,
    fail_login_count integer,
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    created_by_fk integer,
    changed_by_fk integer
);


ALTER TABLE public.ab_user OWNER TO jobuser;

--
-- Name: ab_user_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.ab_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.ab_user_id_seq OWNER TO jobuser;

--
-- Name: ab_user_role; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.ab_user_role (
    id integer NOT NULL,
    user_id integer,
    role_id integer
);


ALTER TABLE public.ab_user_role OWNER TO jobuser;

--
-- Name: ab_user_role_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.ab_user_role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.ab_user_role_id_seq OWNER TO jobuser;

--
-- Name: ab_view_menu; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.ab_view_menu (
    id integer NOT NULL,
    name character varying(255) NOT NULL
);


ALTER TABLE public.ab_view_menu OWNER TO jobuser;

--
-- Name: ab_view_menu_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.ab_view_menu_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.ab_view_menu_id_seq OWNER TO jobuser;

--
-- Name: alembic_version; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.alembic_version (
    version_num character varying(32) NOT NULL
);


ALTER TABLE public.alembic_version OWNER TO jobuser;

--
-- Name: annotation; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.annotation (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    start_dttm timestamp without time zone,
    end_dttm timestamp without time zone,
    layer_id integer,
    short_descr character varying(500),
    long_descr text,
    changed_by_fk integer,
    created_by_fk integer,
    json_metadata text
);


ALTER TABLE public.annotation OWNER TO jobuser;

--
-- Name: annotation_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.annotation_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.annotation_id_seq OWNER TO jobuser;

--
-- Name: annotation_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.annotation_id_seq OWNED BY public.annotation.id;


--
-- Name: annotation_layer; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.annotation_layer (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    name character varying(250),
    descr text,
    changed_by_fk integer,
    created_by_fk integer
);


ALTER TABLE public.annotation_layer OWNER TO jobuser;

--
-- Name: annotation_layer_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.annotation_layer_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.annotation_layer_id_seq OWNER TO jobuser;

--
-- Name: annotation_layer_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.annotation_layer_id_seq OWNED BY public.annotation_layer.id;


--
-- Name: cache_keys; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.cache_keys (
    id integer NOT NULL,
    cache_key character varying(256) NOT NULL,
    cache_timeout integer,
    datasource_uid character varying(64) NOT NULL,
    created_on timestamp without time zone
);


ALTER TABLE public.cache_keys OWNER TO jobuser;

--
-- Name: cache_keys_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.cache_keys_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.cache_keys_id_seq OWNER TO jobuser;

--
-- Name: cache_keys_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.cache_keys_id_seq OWNED BY public.cache_keys.id;


--
-- Name: companies; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.companies (
    id integer NOT NULL,
    name character varying(255) NOT NULL,
    url character varying(255),
    logo_url character varying(255),
    description text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
)
WITH (autovacuum_vacuum_scale_factor='0.1', autovacuum_analyze_scale_factor='0.05');


ALTER TABLE public.companies OWNER TO jobuser;

--
-- Name: companies_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.companies_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.companies_id_seq OWNER TO jobuser;

--
-- Name: companies_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.companies_id_seq OWNED BY public.companies.id;


--
-- Name: css_templates; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.css_templates (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    template_name character varying(250),
    css text,
    changed_by_fk integer,
    created_by_fk integer
);


ALTER TABLE public.css_templates OWNER TO jobuser;

--
-- Name: css_templates_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.css_templates_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.css_templates_id_seq OWNER TO jobuser;

--
-- Name: css_templates_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.css_templates_id_seq OWNED BY public.css_templates.id;


--
-- Name: dashboard_roles; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.dashboard_roles (
    id integer NOT NULL,
    role_id integer NOT NULL,
    dashboard_id integer
);


ALTER TABLE public.dashboard_roles OWNER TO jobuser;

--
-- Name: dashboard_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.dashboard_roles_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dashboard_roles_id_seq OWNER TO jobuser;

--
-- Name: dashboard_roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.dashboard_roles_id_seq OWNED BY public.dashboard_roles.id;


--
-- Name: dashboard_slices; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.dashboard_slices (
    id integer NOT NULL,
    dashboard_id integer,
    slice_id integer
);


ALTER TABLE public.dashboard_slices OWNER TO jobuser;

--
-- Name: dashboard_slices_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.dashboard_slices_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dashboard_slices_id_seq OWNER TO jobuser;

--
-- Name: dashboard_slices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.dashboard_slices_id_seq OWNED BY public.dashboard_slices.id;


--
-- Name: dashboard_user; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.dashboard_user (
    id integer NOT NULL,
    user_id integer,
    dashboard_id integer
);


ALTER TABLE public.dashboard_user OWNER TO jobuser;

--
-- Name: dashboard_user_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.dashboard_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dashboard_user_id_seq OWNER TO jobuser;

--
-- Name: dashboard_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.dashboard_user_id_seq OWNED BY public.dashboard_user.id;


--
-- Name: dashboards; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.dashboards (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    dashboard_title character varying(500),
    position_json text,
    created_by_fk integer,
    changed_by_fk integer,
    css text,
    description text,
    slug character varying(255),
    json_metadata text,
    published boolean,
    uuid uuid,
    certified_by text,
    certification_details text,
    is_managed_externally boolean DEFAULT false NOT NULL,
    external_url text
);


ALTER TABLE public.dashboards OWNER TO jobuser;

--
-- Name: dashboards_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.dashboards_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dashboards_id_seq OWNER TO jobuser;

--
-- Name: dashboards_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.dashboards_id_seq OWNED BY public.dashboards.id;


--
-- Name: database_user_oauth2_tokens; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.database_user_oauth2_tokens (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    user_id integer NOT NULL,
    database_id integer NOT NULL,
    access_token bytea,
    access_token_expiration timestamp without time zone,
    refresh_token bytea,
    created_by_fk integer,
    changed_by_fk integer
);


ALTER TABLE public.database_user_oauth2_tokens OWNER TO jobuser;

--
-- Name: database_user_oauth2_tokens_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.database_user_oauth2_tokens_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.database_user_oauth2_tokens_id_seq OWNER TO jobuser;

--
-- Name: database_user_oauth2_tokens_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.database_user_oauth2_tokens_id_seq OWNED BY public.database_user_oauth2_tokens.id;


--
-- Name: dbs; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.dbs (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    database_name character varying(250) NOT NULL,
    sqlalchemy_uri character varying(1024) NOT NULL,
    created_by_fk integer,
    changed_by_fk integer,
    password bytea,
    cache_timeout integer,
    extra text,
    select_as_create_table_as boolean,
    allow_ctas boolean,
    expose_in_sqllab boolean,
    force_ctas_schema character varying(250),
    allow_run_async boolean,
    allow_dml boolean,
    verbose_name character varying(250),
    impersonate_user boolean,
    allow_file_upload boolean DEFAULT true NOT NULL,
    encrypted_extra bytea,
    server_cert bytea,
    allow_cvas boolean,
    uuid uuid,
    configuration_method character varying(255) DEFAULT 'sqlalchemy_form'::character varying,
    is_managed_externally boolean DEFAULT false NOT NULL,
    external_url text
);


ALTER TABLE public.dbs OWNER TO jobuser;

--
-- Name: dbs_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.dbs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dbs_id_seq OWNER TO jobuser;

--
-- Name: dbs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.dbs_id_seq OWNED BY public.dbs.id;


--
-- Name: dynamic_plugin; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.dynamic_plugin (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    name character varying(50) NOT NULL,
    key character varying(50) NOT NULL,
    bundle_url character varying(1000) NOT NULL,
    created_by_fk integer,
    changed_by_fk integer
);


ALTER TABLE public.dynamic_plugin OWNER TO jobuser;

--
-- Name: dynamic_plugin_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.dynamic_plugin_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.dynamic_plugin_id_seq OWNER TO jobuser;

--
-- Name: dynamic_plugin_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.dynamic_plugin_id_seq OWNED BY public.dynamic_plugin.id;


--
-- Name: embedded_dashboards; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.embedded_dashboards (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    allow_domain_list text,
    uuid uuid,
    dashboard_id integer NOT NULL,
    changed_by_fk integer,
    created_by_fk integer
);


ALTER TABLE public.embedded_dashboards OWNER TO jobuser;

--
-- Name: favstar; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.favstar (
    id integer NOT NULL,
    user_id integer,
    class_name character varying(50),
    obj_id integer,
    dttm timestamp without time zone
);


ALTER TABLE public.favstar OWNER TO jobuser;

--
-- Name: favstar_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.favstar_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.favstar_id_seq OWNER TO jobuser;

--
-- Name: favstar_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.favstar_id_seq OWNED BY public.favstar.id;


--
-- Name: job_batches_new; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_new (
    id integer NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_new OWNER TO jobuser;

--
-- Name: job_batches_new_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.job_batches_new_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.job_batches_new_id_seq OWNER TO jobuser;

--
-- Name: job_batches_new_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.job_batches_new_id_seq OWNED BY public.job_batches_new.id;


--
-- Name: job_batches_partitioned; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_partitioned (
    id integer NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
)
PARTITION BY RANGE (batch_date);


ALTER TABLE public.job_batches_partitioned OWNER TO jobuser;

--
-- Name: TABLE job_batches_partitioned; Type: COMMENT; Schema: public; Owner: jobuser
--

COMMENT ON TABLE public.job_batches_partitioned IS 'Job batches table partitioned by created_at date (monthly).';


--
-- Name: job_batches_partitioned_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.job_batches_partitioned_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.job_batches_partitioned_id_seq OWNER TO jobuser;

--
-- Name: job_batches_partitioned_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.job_batches_partitioned_id_seq OWNED BY public.job_batches_partitioned.id;


--
-- Name: job_batches_p2025_01; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_p2025_01 (
    id integer DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass) NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_p2025_01 OWNER TO jobuser;

--
-- Name: job_batches_p2025_02; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_p2025_02 (
    id integer DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass) NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_p2025_02 OWNER TO jobuser;

--
-- Name: job_batches_p2025_03; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_p2025_03 (
    id integer DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass) NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_p2025_03 OWNER TO jobuser;

--
-- Name: job_batches_p2025_04; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_p2025_04 (
    id integer DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass) NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_p2025_04 OWNER TO jobuser;

--
-- Name: job_batches_p2025_05; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_p2025_05 (
    id integer DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass) NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_p2025_05 OWNER TO jobuser;

--
-- Name: job_batches_p2025_06; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_p2025_06 (
    id integer DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass) NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_p2025_06 OWNER TO jobuser;

--
-- Name: job_batches_p2025_07; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_p2025_07 (
    id integer DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass) NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_p2025_07 OWNER TO jobuser;

--
-- Name: job_batches_p2025_08; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_p2025_08 (
    id integer DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass) NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_p2025_08 OWNER TO jobuser;

--
-- Name: job_batches_p2025_09; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_p2025_09 (
    id integer DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass) NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_p2025_09 OWNER TO jobuser;

--
-- Name: job_batches_p2025_10; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_p2025_10 (
    id integer DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass) NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_p2025_10 OWNER TO jobuser;

--
-- Name: job_batches_p2025_11; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_p2025_11 (
    id integer DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass) NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_p2025_11 OWNER TO jobuser;

--
-- Name: job_batches_p2025_12; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_p2025_12 (
    id integer DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass) NOT NULL,
    batch_date date NOT NULL,
    source character varying(100) NOT NULL,
    job_count integer DEFAULT 0,
    status character varying(50) DEFAULT 'processing'::character varying,
    started_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone,
    notes text
);


ALTER TABLE public.job_batches_p2025_12 OWNER TO jobuser;

--
-- Name: job_categories; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_categories (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
)
WITH (autovacuum_vacuum_scale_factor='0.1', autovacuum_analyze_scale_factor='0.05');


ALTER TABLE public.job_categories OWNER TO jobuser;

--
-- Name: job_categories_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.job_categories_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.job_categories_id_seq OWNER TO jobuser;

--
-- Name: job_categories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.job_categories_id_seq OWNED BY public.job_categories.id;


--
-- Name: job_tags; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_tags (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
)
WITH (autovacuum_vacuum_scale_factor='0.1', autovacuum_analyze_scale_factor='0.05');


ALTER TABLE public.job_tags OWNER TO jobuser;

--
-- Name: job_tags_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.job_tags_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.job_tags_id_seq OWNER TO jobuser;

--
-- Name: job_tags_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.job_tags_id_seq OWNED BY public.job_tags.id;


--
-- Name: jobs_partitioned; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_partitioned (
    id integer NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
)
PARTITION BY RANGE (created_at);


ALTER TABLE public.jobs_partitioned OWNER TO jobuser;

--
-- Name: TABLE jobs_partitioned; Type: COMMENT; Schema: public; Owner: jobuser
--

COMMENT ON TABLE public.jobs_partitioned IS 'Jobs table partitioned by created_at date (monthly). Use the maintain_partitions() function to keep partitions up to date.';


--
-- Name: jobs_partitioned_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.jobs_partitioned_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.jobs_partitioned_id_seq OWNER TO jobuser;

--
-- Name: jobs_partitioned_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.jobs_partitioned_id_seq OWNED BY public.jobs_partitioned.id;


--
-- Name: jobs_p2025_01; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2025_01 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2025_01 OWNER TO jobuser;

--
-- Name: jobs_p2025_02; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2025_02 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2025_02 OWNER TO jobuser;

--
-- Name: jobs_p2025_03; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2025_03 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2025_03 OWNER TO jobuser;

--
-- Name: jobs_p2025_04; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2025_04 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2025_04 OWNER TO jobuser;

--
-- Name: jobs_p2025_05; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2025_05 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2025_05 OWNER TO jobuser;

--
-- Name: jobs_p2025_06; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2025_06 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2025_06 OWNER TO jobuser;

--
-- Name: jobs_p2025_07; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2025_07 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2025_07 OWNER TO jobuser;

--
-- Name: jobs_p2025_08; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2025_08 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2025_08 OWNER TO jobuser;

--
-- Name: jobs_p2025_09; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2025_09 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2025_09 OWNER TO jobuser;

--
-- Name: jobs_p2025_10; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2025_10 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2025_10 OWNER TO jobuser;

--
-- Name: jobs_p2025_11; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2025_11 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2025_11 OWNER TO jobuser;

--
-- Name: jobs_p2025_12; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2025_12 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2025_12 OWNER TO jobuser;

--
-- Name: jobs_p2026_01; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2026_01 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2026_01 OWNER TO jobuser;

--
-- Name: jobs_p2026_02; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2026_02 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2026_02 OWNER TO jobuser;

--
-- Name: jobs_p2026_03; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2026_03 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2026_03 OWNER TO jobuser;

--
-- Name: jobs_p2026_04; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2026_04 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2026_04 OWNER TO jobuser;

--
-- Name: jobs_p2026_05; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2026_05 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2026_05 OWNER TO jobuser;

--
-- Name: jobs_p2026_06; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2026_06 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2026_06 OWNER TO jobuser;

--
-- Name: jobs_p2026_07; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2026_07 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2026_07 OWNER TO jobuser;

--
-- Name: jobs_p2026_08; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2026_08 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2026_08 OWNER TO jobuser;

--
-- Name: jobs_p2026_09; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2026_09 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2026_09 OWNER TO jobuser;

--
-- Name: jobs_p2026_10; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2026_10 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2026_10 OWNER TO jobuser;

--
-- Name: jobs_p2026_11; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2026_11 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2026_11 OWNER TO jobuser;

--
-- Name: jobs_p2026_12; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2026_12 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2026_12 OWNER TO jobuser;

--
-- Name: jobs_p2027_01; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2027_01 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2027_01 OWNER TO jobuser;

--
-- Name: jobs_p2027_02; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2027_02 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2027_02 OWNER TO jobuser;

--
-- Name: jobs_p2027_03; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2027_03 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2027_03 OWNER TO jobuser;

--
-- Name: jobs_p2027_04; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2027_04 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2027_04 OWNER TO jobuser;

--
-- Name: jobs_p2027_05; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2027_05 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2027_05 OWNER TO jobuser;

--
-- Name: jobs_p2027_06; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2027_06 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2027_06 OWNER TO jobuser;

--
-- Name: jobs_p2027_07; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2027_07 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2027_07 OWNER TO jobuser;

--
-- Name: jobs_p2027_08; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2027_08 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2027_08 OWNER TO jobuser;

--
-- Name: jobs_p2027_09; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2027_09 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2027_09 OWNER TO jobuser;

--
-- Name: jobs_p2027_10; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2027_10 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2027_10 OWNER TO jobuser;

--
-- Name: jobs_p2027_11; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2027_11 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2027_11 OWNER TO jobuser;

--
-- Name: jobs_p2027_12; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.jobs_p2027_12 (
    id integer DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass) NOT NULL,
    title text NOT NULL,
    company_id integer,
    description text,
    salary_min integer,
    salary_max integer,
    location_json jsonb,
    job_post_categories jsonb,
    url text,
    tg_channel text,
    tg_message_id integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    job_batch_id integer,
    parent_id integer,
    tags jsonb
);


ALTER TABLE public.jobs_p2027_12 OWNER TO jobuser;

--
-- Name: jobs_view; Type: VIEW; Schema: public; Owner: jobuser
--

CREATE VIEW public.jobs_view AS
 SELECT jobs_partitioned.id,
    jobs_partitioned.title,
    jobs_partitioned.company_id,
    jobs_partitioned.description,
    jobs_partitioned.salary_min,
    jobs_partitioned.salary_max,
    jobs_partitioned.location_json,
    jobs_partitioned.job_post_categories,
    jobs_partitioned.url,
    jobs_partitioned.tg_channel,
    jobs_partitioned.tg_message_id,
    jobs_partitioned.created_at,
    jobs_partitioned.updated_at,
    jobs_partitioned.job_batch_id,
    jobs_partitioned.parent_id,
    jobs_partitioned.tags
   FROM public.jobs_partitioned;


ALTER TABLE public.jobs_view OWNER TO jobuser;

--
-- Name: key_value; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.key_value (
    id integer NOT NULL,
    resource character varying(32) NOT NULL,
    value bytea NOT NULL,
    uuid uuid,
    created_on timestamp without time zone,
    created_by_fk integer,
    changed_on timestamp without time zone,
    changed_by_fk integer,
    expires_on timestamp without time zone
);


ALTER TABLE public.key_value OWNER TO jobuser;

--
-- Name: key_value_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.key_value_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.key_value_id_seq OWNER TO jobuser;

--
-- Name: key_value_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.key_value_id_seq OWNED BY public.key_value.id;


--
-- Name: keyvalue; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.keyvalue (
    id integer NOT NULL,
    value text NOT NULL
);


ALTER TABLE public.keyvalue OWNER TO jobuser;

--
-- Name: keyvalue_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.keyvalue_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.keyvalue_id_seq OWNER TO jobuser;

--
-- Name: keyvalue_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.keyvalue_id_seq OWNED BY public.keyvalue.id;


--
-- Name: locations; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.locations (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    country character varying(100),
    city character varying(100),
    is_remote boolean DEFAULT false,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.locations OWNER TO jobuser;

--
-- Name: locations_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.locations_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.locations_id_seq OWNER TO jobuser;

--
-- Name: locations_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.locations_id_seq OWNED BY public.locations.id;


--
-- Name: logs; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.logs (
    id integer NOT NULL,
    action character varying(512),
    user_id integer,
    json text,
    dttm timestamp without time zone,
    dashboard_id integer,
    slice_id integer,
    duration_ms integer,
    referrer character varying(1024)
);


ALTER TABLE public.logs OWNER TO jobuser;

--
-- Name: logs_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.logs_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.logs_id_seq OWNER TO jobuser;

--
-- Name: logs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.logs_id_seq OWNED BY public.logs.id;


--
-- Name: query; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.query (
    id integer NOT NULL,
    client_id character varying(11) NOT NULL,
    database_id integer NOT NULL,
    tmp_table_name character varying(256),
    tab_name character varying(256),
    sql_editor_id character varying(256),
    user_id integer,
    status character varying(16),
    schema character varying(256),
    sql text,
    select_sql text,
    executed_sql text,
    "limit" integer,
    select_as_cta boolean,
    select_as_cta_used boolean,
    progress integer,
    rows integer,
    error_message text,
    start_time numeric(20,6),
    changed_on timestamp without time zone,
    end_time numeric(20,6),
    results_key character varying(64),
    start_running_time numeric(20,6),
    end_result_backend_time numeric(20,6),
    tracking_url text,
    extra_json text,
    tmp_schema_name character varying(256),
    ctas_method character varying(16),
    limiting_factor character varying(255) DEFAULT 'UNKNOWN'::character varying,
    catalog character varying(256)
);


ALTER TABLE public.query OWNER TO jobuser;

--
-- Name: query_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.query_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.query_id_seq OWNER TO jobuser;

--
-- Name: query_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.query_id_seq OWNED BY public.query.id;


--
-- Name: report_execution_log; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.report_execution_log (
    id integer NOT NULL,
    scheduled_dttm timestamp without time zone NOT NULL,
    start_dttm timestamp without time zone,
    end_dttm timestamp without time zone,
    value double precision,
    value_row_json text,
    state character varying(50) NOT NULL,
    error_message text,
    report_schedule_id integer NOT NULL,
    uuid uuid
);


ALTER TABLE public.report_execution_log OWNER TO jobuser;

--
-- Name: report_execution_log_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.report_execution_log_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.report_execution_log_id_seq OWNER TO jobuser;

--
-- Name: report_execution_log_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.report_execution_log_id_seq OWNED BY public.report_execution_log.id;


--
-- Name: report_recipient; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.report_recipient (
    id integer NOT NULL,
    type character varying(50) NOT NULL,
    recipient_config_json text,
    report_schedule_id integer NOT NULL,
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    created_by_fk integer,
    changed_by_fk integer
);


ALTER TABLE public.report_recipient OWNER TO jobuser;

--
-- Name: report_recipient_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.report_recipient_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.report_recipient_id_seq OWNER TO jobuser;

--
-- Name: report_recipient_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.report_recipient_id_seq OWNED BY public.report_recipient.id;


--
-- Name: report_schedule; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.report_schedule (
    id integer NOT NULL,
    type character varying(50) NOT NULL,
    name character varying(150) NOT NULL,
    description text,
    context_markdown text,
    active boolean,
    crontab character varying(1000) NOT NULL,
    sql text,
    chart_id integer,
    dashboard_id integer,
    database_id integer,
    last_eval_dttm timestamp without time zone,
    last_state character varying(50),
    last_value double precision,
    last_value_row_json text,
    validator_type character varying(100),
    validator_config_json text,
    log_retention integer,
    grace_period integer,
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    created_by_fk integer,
    changed_by_fk integer,
    working_timeout integer,
    report_format character varying(50) DEFAULT 'PNG'::character varying,
    creation_method character varying(255) DEFAULT 'alerts_reports'::character varying,
    timezone character varying(100) DEFAULT 'UTC'::character varying NOT NULL,
    extra_json text NOT NULL,
    force_screenshot boolean,
    custom_width integer,
    custom_height integer,
    email_subject character varying(255)
);


ALTER TABLE public.report_schedule OWNER TO jobuser;

--
-- Name: report_schedule_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.report_schedule_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.report_schedule_id_seq OWNER TO jobuser;

--
-- Name: report_schedule_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.report_schedule_id_seq OWNED BY public.report_schedule.id;


--
-- Name: report_schedule_user; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.report_schedule_user (
    id integer NOT NULL,
    user_id integer NOT NULL,
    report_schedule_id integer NOT NULL
);


ALTER TABLE public.report_schedule_user OWNER TO jobuser;

--
-- Name: report_schedule_user_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.report_schedule_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.report_schedule_user_id_seq OWNER TO jobuser;

--
-- Name: report_schedule_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.report_schedule_user_id_seq OWNED BY public.report_schedule_user.id;


--
-- Name: rls_filter_roles; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.rls_filter_roles (
    id integer NOT NULL,
    role_id integer NOT NULL,
    rls_filter_id integer
);


ALTER TABLE public.rls_filter_roles OWNER TO jobuser;

--
-- Name: rls_filter_roles_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.rls_filter_roles_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.rls_filter_roles_id_seq OWNER TO jobuser;

--
-- Name: rls_filter_roles_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.rls_filter_roles_id_seq OWNED BY public.rls_filter_roles.id;


--
-- Name: rls_filter_tables; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.rls_filter_tables (
    id integer NOT NULL,
    table_id integer,
    rls_filter_id integer
);


ALTER TABLE public.rls_filter_tables OWNER TO jobuser;

--
-- Name: rls_filter_tables_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.rls_filter_tables_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.rls_filter_tables_id_seq OWNER TO jobuser;

--
-- Name: rls_filter_tables_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.rls_filter_tables_id_seq OWNED BY public.rls_filter_tables.id;


--
-- Name: row_level_security_filters; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.row_level_security_filters (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    clause text NOT NULL,
    created_by_fk integer,
    changed_by_fk integer,
    filter_type character varying(255),
    group_key character varying(255),
    name character varying(255) NOT NULL,
    description text
);


ALTER TABLE public.row_level_security_filters OWNER TO jobuser;

--
-- Name: row_level_security_filters_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.row_level_security_filters_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.row_level_security_filters_id_seq OWNER TO jobuser;

--
-- Name: row_level_security_filters_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.row_level_security_filters_id_seq OWNED BY public.row_level_security_filters.id;


--
-- Name: saved_query; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.saved_query (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    user_id integer,
    db_id integer,
    label character varying(256),
    schema character varying(128),
    sql text,
    description text,
    changed_by_fk integer,
    created_by_fk integer,
    extra_json text,
    last_run timestamp without time zone,
    rows integer,
    uuid uuid,
    template_parameters text,
    catalog character varying(256)
);


ALTER TABLE public.saved_query OWNER TO jobuser;

--
-- Name: saved_query_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.saved_query_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.saved_query_id_seq OWNER TO jobuser;

--
-- Name: saved_query_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.saved_query_id_seq OWNED BY public.saved_query.id;


--
-- Name: schema_version; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.schema_version (
    id integer NOT NULL,
    version integer NOT NULL,
    description text,
    applied_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.schema_version OWNER TO jobuser;

--
-- Name: schema_version_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.schema_version_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.schema_version_id_seq OWNER TO jobuser;

--
-- Name: schema_version_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.schema_version_id_seq OWNED BY public.schema_version.id;


--
-- Name: slice_user; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.slice_user (
    id integer NOT NULL,
    user_id integer,
    slice_id integer
);


ALTER TABLE public.slice_user OWNER TO jobuser;

--
-- Name: slice_user_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.slice_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.slice_user_id_seq OWNER TO jobuser;

--
-- Name: slice_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.slice_user_id_seq OWNED BY public.slice_user.id;


--
-- Name: slices; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.slices (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    slice_name character varying(250),
    datasource_type character varying(200),
    datasource_name character varying(2000),
    viz_type character varying(250),
    params text,
    created_by_fk integer,
    changed_by_fk integer,
    description text,
    cache_timeout integer,
    perm character varying(2000),
    datasource_id integer,
    schema_perm character varying(1000),
    uuid uuid,
    query_context text,
    last_saved_at timestamp without time zone,
    last_saved_by_fk integer,
    certified_by text,
    certification_details text,
    is_managed_externally boolean DEFAULT false NOT NULL,
    external_url text,
    catalog_perm character varying(1000),
    CONSTRAINT ck_chart_datasource CHECK (((datasource_type)::text = 'table'::text))
);


ALTER TABLE public.slices OWNER TO jobuser;

--
-- Name: slices_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.slices_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.slices_id_seq OWNER TO jobuser;

--
-- Name: slices_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.slices_id_seq OWNED BY public.slices.id;


--
-- Name: sql_metrics; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.sql_metrics (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    metric_name character varying(255) NOT NULL,
    verbose_name character varying(1024),
    metric_type character varying(32),
    table_id integer,
    expression text NOT NULL,
    description text,
    created_by_fk integer,
    changed_by_fk integer,
    d3format character varying(128),
    warning_text text,
    extra text,
    uuid uuid,
    currency character varying(128)
);


ALTER TABLE public.sql_metrics OWNER TO jobuser;

--
-- Name: sql_metrics_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.sql_metrics_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.sql_metrics_id_seq OWNER TO jobuser;

--
-- Name: sql_metrics_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.sql_metrics_id_seq OWNED BY public.sql_metrics.id;


--
-- Name: sqlatable_user; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.sqlatable_user (
    id integer NOT NULL,
    user_id integer,
    table_id integer
);


ALTER TABLE public.sqlatable_user OWNER TO jobuser;

--
-- Name: sqlatable_user_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.sqlatable_user_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.sqlatable_user_id_seq OWNER TO jobuser;

--
-- Name: sqlatable_user_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.sqlatable_user_id_seq OWNED BY public.sqlatable_user.id;


--
-- Name: ssh_tunnels; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.ssh_tunnels (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    created_by_fk integer,
    changed_by_fk integer,
    extra_json text,
    uuid uuid,
    id integer NOT NULL,
    database_id integer,
    server_address character varying(256),
    server_port integer,
    username bytea,
    password bytea,
    private_key bytea,
    private_key_password bytea
);


ALTER TABLE public.ssh_tunnels OWNER TO jobuser;

--
-- Name: ssh_tunnels_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.ssh_tunnels_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.ssh_tunnels_id_seq OWNER TO jobuser;

--
-- Name: ssh_tunnels_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.ssh_tunnels_id_seq OWNED BY public.ssh_tunnels.id;


--
-- Name: tab_state; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.tab_state (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    extra_json text,
    id integer NOT NULL,
    user_id integer,
    label character varying(256),
    active boolean,
    database_id integer,
    schema character varying(256),
    sql text,
    query_limit integer,
    latest_query_id character varying(11),
    autorun boolean NOT NULL,
    template_params text,
    created_by_fk integer,
    changed_by_fk integer,
    hide_left_bar boolean DEFAULT false NOT NULL,
    saved_query_id integer,
    catalog character varying(256)
);


ALTER TABLE public.tab_state OWNER TO jobuser;

--
-- Name: tab_state_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.tab_state_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.tab_state_id_seq OWNER TO jobuser;

--
-- Name: tab_state_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.tab_state_id_seq OWNED BY public.tab_state.id;


--
-- Name: table_columns; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.table_columns (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    table_id integer,
    column_name character varying(255) NOT NULL,
    is_dttm boolean,
    is_active boolean,
    type text,
    groupby boolean,
    filterable boolean,
    description text,
    created_by_fk integer,
    changed_by_fk integer,
    expression text,
    verbose_name character varying(1024),
    python_date_format character varying(255),
    uuid uuid,
    extra text,
    advanced_data_type character varying(255)
);


ALTER TABLE public.table_columns OWNER TO jobuser;

--
-- Name: table_columns_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.table_columns_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.table_columns_id_seq OWNER TO jobuser;

--
-- Name: table_columns_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.table_columns_id_seq OWNED BY public.table_columns.id;


--
-- Name: table_schema; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.table_schema (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    extra_json text,
    id integer NOT NULL,
    tab_state_id integer,
    database_id integer NOT NULL,
    schema character varying(256),
    "table" character varying(256),
    description text,
    expanded boolean,
    created_by_fk integer,
    changed_by_fk integer,
    catalog character varying(256)
);


ALTER TABLE public.table_schema OWNER TO jobuser;

--
-- Name: table_schema_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.table_schema_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.table_schema_id_seq OWNER TO jobuser;

--
-- Name: table_schema_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.table_schema_id_seq OWNED BY public.table_schema.id;


--
-- Name: tables; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.tables (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    table_name character varying(250) NOT NULL,
    main_dttm_col character varying(250),
    default_endpoint text,
    database_id integer NOT NULL,
    created_by_fk integer,
    changed_by_fk integer,
    "offset" integer,
    description text,
    is_featured boolean,
    cache_timeout integer,
    schema character varying(255),
    sql text,
    params text,
    perm character varying(1000),
    filter_select_enabled boolean,
    fetch_values_predicate text,
    is_sqllab_view boolean DEFAULT false,
    template_params text,
    schema_perm character varying(1000),
    extra text,
    uuid uuid,
    is_managed_externally boolean DEFAULT false NOT NULL,
    external_url text,
    normalize_columns boolean DEFAULT false,
    always_filter_main_dttm boolean DEFAULT false,
    catalog character varying(256),
    catalog_perm character varying(1000)
);


ALTER TABLE public.tables OWNER TO jobuser;

--
-- Name: tables_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.tables_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.tables_id_seq OWNER TO jobuser;

--
-- Name: tables_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.tables_id_seq OWNED BY public.tables.id;


--
-- Name: tag; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.tag (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    name character varying(250),
    type character varying,
    created_by_fk integer,
    changed_by_fk integer,
    description text
);


ALTER TABLE public.tag OWNER TO jobuser;

--
-- Name: tag_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.tag_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.tag_id_seq OWNER TO jobuser;

--
-- Name: tag_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.tag_id_seq OWNED BY public.tag.id;


--
-- Name: tagged_object; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.tagged_object (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    tag_id integer,
    object_id integer,
    object_type character varying,
    created_by_fk integer,
    changed_by_fk integer
);


ALTER TABLE public.tagged_object OWNER TO jobuser;

--
-- Name: tagged_object_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.tagged_object_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.tagged_object_id_seq OWNER TO jobuser;

--
-- Name: tagged_object_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.tagged_object_id_seq OWNED BY public.tagged_object.id;


--
-- Name: user_attribute; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.user_attribute (
    created_on timestamp without time zone,
    changed_on timestamp without time zone,
    id integer NOT NULL,
    user_id integer,
    welcome_dashboard_id integer,
    created_by_fk integer,
    changed_by_fk integer,
    avatar_url character varying(100)
);


ALTER TABLE public.user_attribute OWNER TO jobuser;

--
-- Name: user_attribute_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.user_attribute_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.user_attribute_id_seq OWNER TO jobuser;

--
-- Name: user_attribute_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.user_attribute_id_seq OWNED BY public.user_attribute.id;


--
-- Name: user_favorite_tag; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.user_favorite_tag (
    user_id integer NOT NULL,
    tag_id integer NOT NULL
);


ALTER TABLE public.user_favorite_tag OWNER TO jobuser;

--
-- Name: work_types; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.work_types (
    id integer NOT NULL,
    name character varying(100) NOT NULL,
    description text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.work_types OWNER TO jobuser;

--
-- Name: work_types_id_seq; Type: SEQUENCE; Schema: public; Owner: jobuser
--

CREATE SEQUENCE public.work_types_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.work_types_id_seq OWNER TO jobuser;

--
-- Name: work_types_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: jobuser
--

ALTER SEQUENCE public.work_types_id_seq OWNED BY public.work_types.id;


--
-- Name: job_batches_p2025_01; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ATTACH PARTITION public.job_batches_p2025_01 FOR VALUES FROM ('2025-01-01') TO ('2025-02-01');


--
-- Name: job_batches_p2025_02; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ATTACH PARTITION public.job_batches_p2025_02 FOR VALUES FROM ('2025-02-01') TO ('2025-03-01');


--
-- Name: job_batches_p2025_03; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ATTACH PARTITION public.job_batches_p2025_03 FOR VALUES FROM ('2025-03-01') TO ('2025-04-01');


--
-- Name: job_batches_p2025_04; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ATTACH PARTITION public.job_batches_p2025_04 FOR VALUES FROM ('2025-04-01') TO ('2025-05-01');


--
-- Name: job_batches_p2025_05; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ATTACH PARTITION public.job_batches_p2025_05 FOR VALUES FROM ('2025-05-01') TO ('2025-06-01');


--
-- Name: job_batches_p2025_06; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ATTACH PARTITION public.job_batches_p2025_06 FOR VALUES FROM ('2025-06-01') TO ('2025-07-01');


--
-- Name: job_batches_p2025_07; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ATTACH PARTITION public.job_batches_p2025_07 FOR VALUES FROM ('2025-07-01') TO ('2025-08-01');


--
-- Name: job_batches_p2025_08; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ATTACH PARTITION public.job_batches_p2025_08 FOR VALUES FROM ('2025-08-01') TO ('2025-09-01');


--
-- Name: job_batches_p2025_09; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ATTACH PARTITION public.job_batches_p2025_09 FOR VALUES FROM ('2025-09-01') TO ('2025-10-01');


--
-- Name: job_batches_p2025_10; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ATTACH PARTITION public.job_batches_p2025_10 FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');


--
-- Name: job_batches_p2025_11; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ATTACH PARTITION public.job_batches_p2025_11 FOR VALUES FROM ('2025-11-01') TO ('2025-12-01');


--
-- Name: job_batches_p2025_12; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ATTACH PARTITION public.job_batches_p2025_12 FOR VALUES FROM ('2025-12-01') TO ('2026-01-01');


--
-- Name: jobs_p2025_01; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2025_01 FOR VALUES FROM ('2025-01-01 00:00:00+03:30') TO ('2025-02-01 00:00:00+03:30');


--
-- Name: jobs_p2025_02; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2025_02 FOR VALUES FROM ('2025-02-01 00:00:00+03:30') TO ('2025-03-01 00:00:00+03:30');


--
-- Name: jobs_p2025_03; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2025_03 FOR VALUES FROM ('2025-03-01 00:00:00+03:30') TO ('2025-04-01 00:00:00+03:30');


--
-- Name: jobs_p2025_04; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2025_04 FOR VALUES FROM ('2025-04-01 00:00:00+03:30') TO ('2025-05-01 00:00:00+03:30');


--
-- Name: jobs_p2025_05; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2025_05 FOR VALUES FROM ('2025-05-01 00:00:00+03:30') TO ('2025-06-01 00:00:00+03:30');


--
-- Name: jobs_p2025_06; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2025_06 FOR VALUES FROM ('2025-06-01 00:00:00+03:30') TO ('2025-07-01 00:00:00+03:30');


--
-- Name: jobs_p2025_07; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2025_07 FOR VALUES FROM ('2025-07-01 00:00:00+03:30') TO ('2025-08-01 00:00:00+03:30');


--
-- Name: jobs_p2025_08; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2025_08 FOR VALUES FROM ('2025-08-01 00:00:00+03:30') TO ('2025-09-01 00:00:00+03:30');


--
-- Name: jobs_p2025_09; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2025_09 FOR VALUES FROM ('2025-09-01 00:00:00+03:30') TO ('2025-10-01 00:00:00+03:30');


--
-- Name: jobs_p2025_10; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2025_10 FOR VALUES FROM ('2025-10-01 00:00:00+03:30') TO ('2025-11-01 00:00:00+03:30');


--
-- Name: jobs_p2025_11; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2025_11 FOR VALUES FROM ('2025-11-01 00:00:00+03:30') TO ('2025-12-01 00:00:00+03:30');


--
-- Name: jobs_p2025_12; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2025_12 FOR VALUES FROM ('2025-12-01 00:00:00+03:30') TO ('2026-01-01 00:00:00+03:30');


--
-- Name: jobs_p2026_01; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2026_01 FOR VALUES FROM ('2026-01-01 00:00:00+03:30') TO ('2026-02-01 00:00:00+03:30');


--
-- Name: jobs_p2026_02; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2026_02 FOR VALUES FROM ('2026-02-01 00:00:00+03:30') TO ('2026-03-01 00:00:00+03:30');


--
-- Name: jobs_p2026_03; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2026_03 FOR VALUES FROM ('2026-03-01 00:00:00+03:30') TO ('2026-04-01 00:00:00+03:30');


--
-- Name: jobs_p2026_04; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2026_04 FOR VALUES FROM ('2026-04-01 00:00:00+03:30') TO ('2026-05-01 00:00:00+03:30');


--
-- Name: jobs_p2026_05; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2026_05 FOR VALUES FROM ('2026-05-01 00:00:00+03:30') TO ('2026-06-01 00:00:00+03:30');


--
-- Name: jobs_p2026_06; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2026_06 FOR VALUES FROM ('2026-06-01 00:00:00+03:30') TO ('2026-07-01 00:00:00+03:30');


--
-- Name: jobs_p2026_07; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2026_07 FOR VALUES FROM ('2026-07-01 00:00:00+03:30') TO ('2026-08-01 00:00:00+03:30');


--
-- Name: jobs_p2026_08; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2026_08 FOR VALUES FROM ('2026-08-01 00:00:00+03:30') TO ('2026-09-01 00:00:00+03:30');


--
-- Name: jobs_p2026_09; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2026_09 FOR VALUES FROM ('2026-09-01 00:00:00+03:30') TO ('2026-10-01 00:00:00+03:30');


--
-- Name: jobs_p2026_10; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2026_10 FOR VALUES FROM ('2026-10-01 00:00:00+03:30') TO ('2026-11-01 00:00:00+03:30');


--
-- Name: jobs_p2026_11; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2026_11 FOR VALUES FROM ('2026-11-01 00:00:00+03:30') TO ('2026-12-01 00:00:00+03:30');


--
-- Name: jobs_p2026_12; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2026_12 FOR VALUES FROM ('2026-12-01 00:00:00+03:30') TO ('2027-01-01 00:00:00+03:30');


--
-- Name: jobs_p2027_01; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2027_01 FOR VALUES FROM ('2027-01-01 00:00:00+03:30') TO ('2027-02-01 00:00:00+03:30');


--
-- Name: jobs_p2027_02; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2027_02 FOR VALUES FROM ('2027-02-01 00:00:00+03:30') TO ('2027-03-01 00:00:00+03:30');


--
-- Name: jobs_p2027_03; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2027_03 FOR VALUES FROM ('2027-03-01 00:00:00+03:30') TO ('2027-04-01 00:00:00+03:30');


--
-- Name: jobs_p2027_04; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2027_04 FOR VALUES FROM ('2027-04-01 00:00:00+03:30') TO ('2027-05-01 00:00:00+03:30');


--
-- Name: jobs_p2027_05; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2027_05 FOR VALUES FROM ('2027-05-01 00:00:00+03:30') TO ('2027-06-01 00:00:00+03:30');


--
-- Name: jobs_p2027_06; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2027_06 FOR VALUES FROM ('2027-06-01 00:00:00+03:30') TO ('2027-07-01 00:00:00+03:30');


--
-- Name: jobs_p2027_07; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2027_07 FOR VALUES FROM ('2027-07-01 00:00:00+03:30') TO ('2027-08-01 00:00:00+03:30');


--
-- Name: jobs_p2027_08; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2027_08 FOR VALUES FROM ('2027-08-01 00:00:00+03:30') TO ('2027-09-01 00:00:00+03:30');


--
-- Name: jobs_p2027_09; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2027_09 FOR VALUES FROM ('2027-09-01 00:00:00+03:30') TO ('2027-10-01 00:00:00+03:30');


--
-- Name: jobs_p2027_10; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2027_10 FOR VALUES FROM ('2027-10-01 00:00:00+03:30') TO ('2027-11-01 00:00:00+03:30');


--
-- Name: jobs_p2027_11; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2027_11 FOR VALUES FROM ('2027-11-01 00:00:00+03:30') TO ('2027-12-01 00:00:00+03:30');


--
-- Name: jobs_p2027_12; Type: TABLE ATTACH; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ATTACH PARTITION public.jobs_p2027_12 FOR VALUES FROM ('2027-12-01 00:00:00+03:30') TO ('2028-01-01 00:00:00+03:30');


--
-- Name: annotation id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.annotation ALTER COLUMN id SET DEFAULT nextval('public.annotation_id_seq'::regclass);


--
-- Name: annotation_layer id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.annotation_layer ALTER COLUMN id SET DEFAULT nextval('public.annotation_layer_id_seq'::regclass);


--
-- Name: cache_keys id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.cache_keys ALTER COLUMN id SET DEFAULT nextval('public.cache_keys_id_seq'::regclass);


--
-- Name: companies id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.companies ALTER COLUMN id SET DEFAULT nextval('public.companies_id_seq'::regclass);


--
-- Name: css_templates id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.css_templates ALTER COLUMN id SET DEFAULT nextval('public.css_templates_id_seq'::regclass);


--
-- Name: dashboard_roles id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_roles ALTER COLUMN id SET DEFAULT nextval('public.dashboard_roles_id_seq'::regclass);


--
-- Name: dashboard_slices id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_slices ALTER COLUMN id SET DEFAULT nextval('public.dashboard_slices_id_seq'::regclass);


--
-- Name: dashboard_user id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_user ALTER COLUMN id SET DEFAULT nextval('public.dashboard_user_id_seq'::regclass);


--
-- Name: dashboards id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboards ALTER COLUMN id SET DEFAULT nextval('public.dashboards_id_seq'::regclass);


--
-- Name: database_user_oauth2_tokens id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.database_user_oauth2_tokens ALTER COLUMN id SET DEFAULT nextval('public.database_user_oauth2_tokens_id_seq'::regclass);


--
-- Name: dbs id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dbs ALTER COLUMN id SET DEFAULT nextval('public.dbs_id_seq'::regclass);


--
-- Name: dynamic_plugin id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dynamic_plugin ALTER COLUMN id SET DEFAULT nextval('public.dynamic_plugin_id_seq'::regclass);


--
-- Name: favstar id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.favstar ALTER COLUMN id SET DEFAULT nextval('public.favstar_id_seq'::regclass);


--
-- Name: job_batches_new id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_new ALTER COLUMN id SET DEFAULT nextval('public.job_batches_new_id_seq'::regclass);


--
-- Name: job_batches_partitioned id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ALTER COLUMN id SET DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass);


--
-- Name: job_categories id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_categories ALTER COLUMN id SET DEFAULT nextval('public.job_categories_id_seq'::regclass);


--
-- Name: job_tags id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_tags ALTER COLUMN id SET DEFAULT nextval('public.job_tags_id_seq'::regclass);


--
-- Name: jobs_partitioned id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned ALTER COLUMN id SET DEFAULT nextval('public.jobs_partitioned_id_seq'::regclass);


--
-- Name: key_value id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.key_value ALTER COLUMN id SET DEFAULT nextval('public.key_value_id_seq'::regclass);


--
-- Name: keyvalue id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.keyvalue ALTER COLUMN id SET DEFAULT nextval('public.keyvalue_id_seq'::regclass);


--
-- Name: locations id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.locations ALTER COLUMN id SET DEFAULT nextval('public.locations_id_seq'::regclass);


--
-- Name: logs id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.logs ALTER COLUMN id SET DEFAULT nextval('public.logs_id_seq'::regclass);


--
-- Name: query id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.query ALTER COLUMN id SET DEFAULT nextval('public.query_id_seq'::regclass);


--
-- Name: report_execution_log id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_execution_log ALTER COLUMN id SET DEFAULT nextval('public.report_execution_log_id_seq'::regclass);


--
-- Name: report_recipient id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_recipient ALTER COLUMN id SET DEFAULT nextval('public.report_recipient_id_seq'::regclass);


--
-- Name: report_schedule id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_schedule ALTER COLUMN id SET DEFAULT nextval('public.report_schedule_id_seq'::regclass);


--
-- Name: report_schedule_user id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_schedule_user ALTER COLUMN id SET DEFAULT nextval('public.report_schedule_user_id_seq'::regclass);


--
-- Name: rls_filter_roles id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.rls_filter_roles ALTER COLUMN id SET DEFAULT nextval('public.rls_filter_roles_id_seq'::regclass);


--
-- Name: rls_filter_tables id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.rls_filter_tables ALTER COLUMN id SET DEFAULT nextval('public.rls_filter_tables_id_seq'::regclass);


--
-- Name: row_level_security_filters id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.row_level_security_filters ALTER COLUMN id SET DEFAULT nextval('public.row_level_security_filters_id_seq'::regclass);


--
-- Name: saved_query id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.saved_query ALTER COLUMN id SET DEFAULT nextval('public.saved_query_id_seq'::regclass);


--
-- Name: schema_version id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.schema_version ALTER COLUMN id SET DEFAULT nextval('public.schema_version_id_seq'::regclass);


--
-- Name: slice_user id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.slice_user ALTER COLUMN id SET DEFAULT nextval('public.slice_user_id_seq'::regclass);


--
-- Name: slices id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.slices ALTER COLUMN id SET DEFAULT nextval('public.slices_id_seq'::regclass);


--
-- Name: sql_metrics id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.sql_metrics ALTER COLUMN id SET DEFAULT nextval('public.sql_metrics_id_seq'::regclass);


--
-- Name: sqlatable_user id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.sqlatable_user ALTER COLUMN id SET DEFAULT nextval('public.sqlatable_user_id_seq'::regclass);


--
-- Name: ssh_tunnels id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ssh_tunnels ALTER COLUMN id SET DEFAULT nextval('public.ssh_tunnels_id_seq'::regclass);


--
-- Name: tab_state id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tab_state ALTER COLUMN id SET DEFAULT nextval('public.tab_state_id_seq'::regclass);


--
-- Name: table_columns id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_columns ALTER COLUMN id SET DEFAULT nextval('public.table_columns_id_seq'::regclass);


--
-- Name: table_schema id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_schema ALTER COLUMN id SET DEFAULT nextval('public.table_schema_id_seq'::regclass);


--
-- Name: tables id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tables ALTER COLUMN id SET DEFAULT nextval('public.tables_id_seq'::regclass);


--
-- Name: tag id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tag ALTER COLUMN id SET DEFAULT nextval('public.tag_id_seq'::regclass);


--
-- Name: tagged_object id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tagged_object ALTER COLUMN id SET DEFAULT nextval('public.tagged_object_id_seq'::regclass);


--
-- Name: user_attribute id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.user_attribute ALTER COLUMN id SET DEFAULT nextval('public.user_attribute_id_seq'::regclass);


--
-- Name: work_types id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.work_types ALTER COLUMN id SET DEFAULT nextval('public.work_types_id_seq'::regclass);


--
-- Data for Name: ab_permission; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.ab_permission (id, name) FROM stdin;
1	can_read
2	can_write
3	can_view_chart_as_table
4	can_view_query
5	can_csv_upload
6	can_excel_upload
7	can_columnar_upload
\.


--
-- Data for Name: ab_permission_view; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.ab_permission_view (id, permission_id, view_menu_id) FROM stdin;
1	1	1
2	2	1
3	1	2
4	2	2
5	1	3
6	2	3
7	1	4
8	2	4
9	1	5
10	2	5
11	1	6
12	2	6
13	1	7
14	2	7
15	1	8
16	2	8
17	1	9
18	2	9
19	1	10
20	3	8
21	4	8
22	5	9
23	6	9
24	7	9
\.


--
-- Data for Name: ab_permission_view_role; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.ab_permission_view_role (id, permission_view_id, role_id) FROM stdin;
\.


--
-- Data for Name: ab_register_user; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.ab_register_user (id, first_name, last_name, username, password, email, registration_date, registration_hash) FROM stdin;
\.


--
-- Data for Name: ab_role; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.ab_role (id, name) FROM stdin;
1	Admin
2	Public
\.


--
-- Data for Name: ab_user; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.ab_user (id, first_name, last_name, username, password, active, email, last_login, login_count, fail_login_count, created_on, changed_on, created_by_fk, changed_by_fk) FROM stdin;
\.


--
-- Data for Name: ab_user_role; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.ab_user_role (id, user_id, role_id) FROM stdin;
\.


--
-- Data for Name: ab_view_menu; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.ab_view_menu (id, name) FROM stdin;
1	SavedQuery
2	CssTemplate
3	ReportSchedule
4	Chart
5	Annotation
6	Dataset
7	Log
8	Dashboard
9	Database
10	Query
\.


--
-- Data for Name: alembic_version; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.alembic_version (version_num) FROM stdin;
48cbb571fa3a
\.


--
-- Data for Name: annotation; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.annotation (created_on, changed_on, id, start_dttm, end_dttm, layer_id, short_descr, long_descr, changed_by_fk, created_by_fk, json_metadata) FROM stdin;
\.


--
-- Data for Name: annotation_layer; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.annotation_layer (created_on, changed_on, id, name, descr, changed_by_fk, created_by_fk) FROM stdin;
\.


--
-- Data for Name: cache_keys; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.cache_keys (id, cache_key, cache_timeout, datasource_uid, created_on) FROM stdin;
\.


--
-- Data for Name: companies; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.companies (id, name, url, logo_url, description, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: css_templates; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.css_templates (created_on, changed_on, id, template_name, css, changed_by_fk, created_by_fk) FROM stdin;
\.


--
-- Data for Name: dashboard_roles; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.dashboard_roles (id, role_id, dashboard_id) FROM stdin;
\.


--
-- Data for Name: dashboard_slices; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.dashboard_slices (id, dashboard_id, slice_id) FROM stdin;
\.


--
-- Data for Name: dashboard_user; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.dashboard_user (id, user_id, dashboard_id) FROM stdin;
\.


--
-- Data for Name: dashboards; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.dashboards (created_on, changed_on, id, dashboard_title, position_json, created_by_fk, changed_by_fk, css, description, slug, json_metadata, published, uuid, certified_by, certification_details, is_managed_externally, external_url) FROM stdin;
\.


--
-- Data for Name: database_user_oauth2_tokens; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.database_user_oauth2_tokens (created_on, changed_on, id, user_id, database_id, access_token, access_token_expiration, refresh_token, created_by_fk, changed_by_fk) FROM stdin;
\.


--
-- Data for Name: dbs; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.dbs (created_on, changed_on, id, database_name, sqlalchemy_uri, created_by_fk, changed_by_fk, password, cache_timeout, extra, select_as_create_table_as, allow_ctas, expose_in_sqllab, force_ctas_schema, allow_run_async, allow_dml, verbose_name, impersonate_user, allow_file_upload, encrypted_extra, server_cert, allow_cvas, uuid, configuration_method, is_managed_externally, external_url) FROM stdin;
\.


--
-- Data for Name: dynamic_plugin; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.dynamic_plugin (created_on, changed_on, id, name, key, bundle_url, created_by_fk, changed_by_fk) FROM stdin;
\.


--
-- Data for Name: embedded_dashboards; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.embedded_dashboards (created_on, changed_on, allow_domain_list, uuid, dashboard_id, changed_by_fk, created_by_fk) FROM stdin;
\.


--
-- Data for Name: favstar; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.favstar (id, user_id, class_name, obj_id, dttm) FROM stdin;
\.


--
-- Data for Name: job_batches_new; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_new (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_batches_p2025_01; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_p2025_01 (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_batches_p2025_02; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_p2025_02 (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_batches_p2025_03; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_p2025_03 (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_batches_p2025_04; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_p2025_04 (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_batches_p2025_05; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_p2025_05 (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_batches_p2025_06; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_p2025_06 (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_batches_p2025_07; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_p2025_07 (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_batches_p2025_08; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_p2025_08 (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_batches_p2025_09; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_p2025_09 (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_batches_p2025_10; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_p2025_10 (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_batches_p2025_11; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_p2025_11 (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_batches_p2025_12; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_p2025_12 (id, batch_date, source, job_count, status, started_at, completed_at, notes) FROM stdin;
\.


--
-- Data for Name: job_categories; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_categories (id, name, description, created_at) FROM stdin;
\.


--
-- Data for Name: job_tags; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_tags (id, name, description, created_at) FROM stdin;
\.


--
-- Data for Name: jobs_p2025_01; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2025_01 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2025_02; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2025_02 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2025_03; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2025_03 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2025_04; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2025_04 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2025_05; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2025_05 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2025_06; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2025_06 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2025_07; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2025_07 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2025_08; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2025_08 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2025_09; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2025_09 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2025_10; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2025_10 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2025_11; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2025_11 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2025_12; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2025_12 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2026_01; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2026_01 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2026_02; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2026_02 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2026_03; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2026_03 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2026_04; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2026_04 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2026_05; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2026_05 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2026_06; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2026_06 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2026_07; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2026_07 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2026_08; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2026_08 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2026_09; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2026_09 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2026_10; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2026_10 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2026_11; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2026_11 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2026_12; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2026_12 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2027_01; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2027_01 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2027_02; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2027_02 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2027_03; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2027_03 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2027_04; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2027_04 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2027_05; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2027_05 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2027_06; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2027_06 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2027_07; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2027_07 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2027_08; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2027_08 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2027_09; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2027_09 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2027_10; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2027_10 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2027_11; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2027_11 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: jobs_p2027_12; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.jobs_p2027_12 (id, title, company_id, description, salary_min, salary_max, location_json, job_post_categories, url, tg_channel, tg_message_id, created_at, updated_at, job_batch_id, parent_id, tags) FROM stdin;
\.


--
-- Data for Name: key_value; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.key_value (id, resource, value, uuid, created_on, created_by_fk, changed_on, changed_by_fk, expires_on) FROM stdin;
\.


--
-- Data for Name: keyvalue; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.keyvalue (id, value) FROM stdin;
\.


--
-- Data for Name: locations; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.locations (id, name, country, city, is_remote, created_at) FROM stdin;
1	Remote	\N	\N	t	2025-04-04 20:33:37.178473
2	Tehran	\N	\N	f	2025-04-04 20:33:37.178473
3	Mashhad	\N	\N	f	2025-04-04 20:33:37.178473
4	Isfahan	\N	\N	f	2025-04-04 20:33:37.178473
5	Shiraz	\N	\N	f	2025-04-04 20:33:37.178473
\.


--
-- Data for Name: logs; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.logs (id, action, user_id, json, dttm, dashboard_id, slice_id, duration_ms, referrer) FROM stdin;
\.


--
-- Data for Name: query; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.query (id, client_id, database_id, tmp_table_name, tab_name, sql_editor_id, user_id, status, schema, sql, select_sql, executed_sql, "limit", select_as_cta, select_as_cta_used, progress, rows, error_message, start_time, changed_on, end_time, results_key, start_running_time, end_result_backend_time, tracking_url, extra_json, tmp_schema_name, ctas_method, limiting_factor, catalog) FROM stdin;
\.


--
-- Data for Name: report_execution_log; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.report_execution_log (id, scheduled_dttm, start_dttm, end_dttm, value, value_row_json, state, error_message, report_schedule_id, uuid) FROM stdin;
\.


--
-- Data for Name: report_recipient; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.report_recipient (id, type, recipient_config_json, report_schedule_id, created_on, changed_on, created_by_fk, changed_by_fk) FROM stdin;
\.


--
-- Data for Name: report_schedule; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.report_schedule (id, type, name, description, context_markdown, active, crontab, sql, chart_id, dashboard_id, database_id, last_eval_dttm, last_state, last_value, last_value_row_json, validator_type, validator_config_json, log_retention, grace_period, created_on, changed_on, created_by_fk, changed_by_fk, working_timeout, report_format, creation_method, timezone, extra_json, force_screenshot, custom_width, custom_height, email_subject) FROM stdin;
\.


--
-- Data for Name: report_schedule_user; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.report_schedule_user (id, user_id, report_schedule_id) FROM stdin;
\.


--
-- Data for Name: rls_filter_roles; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.rls_filter_roles (id, role_id, rls_filter_id) FROM stdin;
\.


--
-- Data for Name: rls_filter_tables; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.rls_filter_tables (id, table_id, rls_filter_id) FROM stdin;
\.


--
-- Data for Name: row_level_security_filters; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.row_level_security_filters (created_on, changed_on, id, clause, created_by_fk, changed_by_fk, filter_type, group_key, name, description) FROM stdin;
\.


--
-- Data for Name: saved_query; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.saved_query (created_on, changed_on, id, user_id, db_id, label, schema, sql, description, changed_by_fk, created_by_fk, extra_json, last_run, rows, uuid, template_parameters, catalog) FROM stdin;
\.


--
-- Data for Name: schema_version; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.schema_version (id, version, description, applied_at) FROM stdin;
1	2	Initial normalized schema migration	2025-04-04 20:33:38.134552
\.


--
-- Data for Name: slice_user; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.slice_user (id, user_id, slice_id) FROM stdin;
\.


--
-- Data for Name: slices; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.slices (created_on, changed_on, id, slice_name, datasource_type, datasource_name, viz_type, params, created_by_fk, changed_by_fk, description, cache_timeout, perm, datasource_id, schema_perm, uuid, query_context, last_saved_at, last_saved_by_fk, certified_by, certification_details, is_managed_externally, external_url, catalog_perm) FROM stdin;
\.


--
-- Data for Name: sql_metrics; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.sql_metrics (created_on, changed_on, id, metric_name, verbose_name, metric_type, table_id, expression, description, created_by_fk, changed_by_fk, d3format, warning_text, extra, uuid, currency) FROM stdin;
\.


--
-- Data for Name: sqlatable_user; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.sqlatable_user (id, user_id, table_id) FROM stdin;
\.


--
-- Data for Name: ssh_tunnels; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.ssh_tunnels (created_on, changed_on, created_by_fk, changed_by_fk, extra_json, uuid, id, database_id, server_address, server_port, username, password, private_key, private_key_password) FROM stdin;
\.


--
-- Data for Name: tab_state; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.tab_state (created_on, changed_on, extra_json, id, user_id, label, active, database_id, schema, sql, query_limit, latest_query_id, autorun, template_params, created_by_fk, changed_by_fk, hide_left_bar, saved_query_id, catalog) FROM stdin;
\.


--
-- Data for Name: table_columns; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.table_columns (created_on, changed_on, id, table_id, column_name, is_dttm, is_active, type, groupby, filterable, description, created_by_fk, changed_by_fk, expression, verbose_name, python_date_format, uuid, extra, advanced_data_type) FROM stdin;
\.


--
-- Data for Name: table_schema; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.table_schema (created_on, changed_on, extra_json, id, tab_state_id, database_id, schema, "table", description, expanded, created_by_fk, changed_by_fk, catalog) FROM stdin;
\.


--
-- Data for Name: tables; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.tables (created_on, changed_on, id, table_name, main_dttm_col, default_endpoint, database_id, created_by_fk, changed_by_fk, "offset", description, is_featured, cache_timeout, schema, sql, params, perm, filter_select_enabled, fetch_values_predicate, is_sqllab_view, template_params, schema_perm, extra, uuid, is_managed_externally, external_url, normalize_columns, always_filter_main_dttm, catalog, catalog_perm) FROM stdin;
\.


--
-- Data for Name: tag; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.tag (created_on, changed_on, id, name, type, created_by_fk, changed_by_fk, description) FROM stdin;
\.


--
-- Data for Name: tagged_object; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.tagged_object (created_on, changed_on, id, tag_id, object_id, object_type, created_by_fk, changed_by_fk) FROM stdin;
\.


--
-- Data for Name: user_attribute; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.user_attribute (created_on, changed_on, id, user_id, welcome_dashboard_id, created_by_fk, changed_by_fk, avatar_url) FROM stdin;
\.


--
-- Data for Name: user_favorite_tag; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.user_favorite_tag (user_id, tag_id) FROM stdin;
\.


--
-- Data for Name: work_types; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.work_types (id, name, description, created_at) FROM stdin;
1	Full-time	\N	2025-04-04 20:33:37.176772
2	Part-time	\N	2025-04-04 20:33:37.176772
3	Contract	\N	2025-04-04 20:33:37.176772
4	Freelance	\N	2025-04-04 20:33:37.176772
5	Internship	\N	2025-04-04 20:33:37.176772
\.


--
-- Name: ab_permission_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.ab_permission_id_seq', 7, true);


--
-- Name: ab_permission_view_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.ab_permission_view_id_seq', 24, true);


--
-- Name: ab_permission_view_role_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.ab_permission_view_role_id_seq', 1, false);


--
-- Name: ab_register_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.ab_register_user_id_seq', 1, false);


--
-- Name: ab_role_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.ab_role_id_seq', 2, true);


--
-- Name: ab_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.ab_user_id_seq', 1, false);


--
-- Name: ab_user_role_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.ab_user_role_id_seq', 1, false);


--
-- Name: ab_view_menu_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.ab_view_menu_id_seq', 10, true);


--
-- Name: annotation_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.annotation_id_seq', 1, false);


--
-- Name: annotation_layer_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.annotation_layer_id_seq', 1, false);


--
-- Name: cache_keys_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.cache_keys_id_seq', 1, false);


--
-- Name: companies_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.companies_id_seq', 1, false);


--
-- Name: css_templates_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.css_templates_id_seq', 1, false);


--
-- Name: dashboard_roles_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.dashboard_roles_id_seq', 1, false);


--
-- Name: dashboard_slices_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.dashboard_slices_id_seq', 1, false);


--
-- Name: dashboard_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.dashboard_user_id_seq', 1, false);


--
-- Name: dashboards_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.dashboards_id_seq', 1, false);


--
-- Name: database_user_oauth2_tokens_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.database_user_oauth2_tokens_id_seq', 1, false);


--
-- Name: dbs_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.dbs_id_seq', 1, false);


--
-- Name: dynamic_plugin_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.dynamic_plugin_id_seq', 1, false);


--
-- Name: favstar_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.favstar_id_seq', 1, false);


--
-- Name: job_batches_new_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.job_batches_new_id_seq', 1, false);


--
-- Name: job_batches_partitioned_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.job_batches_partitioned_id_seq', 1, false);


--
-- Name: job_categories_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.job_categories_id_seq', 1, false);


--
-- Name: job_tags_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.job_tags_id_seq', 1, false);


--
-- Name: jobs_partitioned_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.jobs_partitioned_id_seq', 1, false);


--
-- Name: key_value_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.key_value_id_seq', 1, false);


--
-- Name: keyvalue_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.keyvalue_id_seq', 1, false);


--
-- Name: locations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.locations_id_seq', 5, true);


--
-- Name: logs_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.logs_id_seq', 1, false);


--
-- Name: query_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.query_id_seq', 1, false);


--
-- Name: report_execution_log_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.report_execution_log_id_seq', 1, false);


--
-- Name: report_recipient_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.report_recipient_id_seq', 1, false);


--
-- Name: report_schedule_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.report_schedule_id_seq', 1, false);


--
-- Name: report_schedule_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.report_schedule_user_id_seq', 1, false);


--
-- Name: rls_filter_roles_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.rls_filter_roles_id_seq', 1, false);


--
-- Name: rls_filter_tables_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.rls_filter_tables_id_seq', 1, false);


--
-- Name: row_level_security_filters_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.row_level_security_filters_id_seq', 1, false);


--
-- Name: saved_query_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.saved_query_id_seq', 1, false);


--
-- Name: schema_version_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.schema_version_id_seq', 1, true);


--
-- Name: slice_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.slice_user_id_seq', 1, false);


--
-- Name: slices_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.slices_id_seq', 1, false);


--
-- Name: sql_metrics_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.sql_metrics_id_seq', 1, false);


--
-- Name: sqlatable_user_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.sqlatable_user_id_seq', 1, false);


--
-- Name: ssh_tunnels_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.ssh_tunnels_id_seq', 1, false);


--
-- Name: tab_state_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.tab_state_id_seq', 1, false);


--
-- Name: table_columns_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.table_columns_id_seq', 1, false);


--
-- Name: table_schema_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.table_schema_id_seq', 1, false);


--
-- Name: tables_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.tables_id_seq', 1, false);


--
-- Name: tag_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.tag_id_seq', 1, false);


--
-- Name: tagged_object_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.tagged_object_id_seq', 1, false);


--
-- Name: user_attribute_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.user_attribute_id_seq', 1, false);


--
-- Name: work_types_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.work_types_id_seq', 5, true);


--
-- Name: tables _customer_location_uc; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tables
    ADD CONSTRAINT _customer_location_uc UNIQUE (database_id, schema, table_name);


--
-- Name: ab_permission ab_permission_name_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_permission
    ADD CONSTRAINT ab_permission_name_key UNIQUE (name);


--
-- Name: ab_permission ab_permission_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_permission
    ADD CONSTRAINT ab_permission_pkey PRIMARY KEY (id);


--
-- Name: ab_permission_view ab_permission_view_permission_id_view_menu_id_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_permission_view
    ADD CONSTRAINT ab_permission_view_permission_id_view_menu_id_key UNIQUE (permission_id, view_menu_id);


--
-- Name: ab_permission_view ab_permission_view_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_permission_view
    ADD CONSTRAINT ab_permission_view_pkey PRIMARY KEY (id);


--
-- Name: ab_permission_view_role ab_permission_view_role_permission_view_id_role_id_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_permission_view_role
    ADD CONSTRAINT ab_permission_view_role_permission_view_id_role_id_key UNIQUE (permission_view_id, role_id);


--
-- Name: ab_permission_view_role ab_permission_view_role_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_permission_view_role
    ADD CONSTRAINT ab_permission_view_role_pkey PRIMARY KEY (id);


--
-- Name: ab_register_user ab_register_user_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_register_user
    ADD CONSTRAINT ab_register_user_pkey PRIMARY KEY (id);


--
-- Name: ab_register_user ab_register_user_username_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_register_user
    ADD CONSTRAINT ab_register_user_username_key UNIQUE (username);


--
-- Name: ab_role ab_role_name_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_role
    ADD CONSTRAINT ab_role_name_key UNIQUE (name);


--
-- Name: ab_role ab_role_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_role
    ADD CONSTRAINT ab_role_pkey PRIMARY KEY (id);


--
-- Name: ab_user ab_user_email_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_user
    ADD CONSTRAINT ab_user_email_key UNIQUE (email);


--
-- Name: ab_user ab_user_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_user
    ADD CONSTRAINT ab_user_pkey PRIMARY KEY (id);


--
-- Name: ab_user_role ab_user_role_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_user_role
    ADD CONSTRAINT ab_user_role_pkey PRIMARY KEY (id);


--
-- Name: ab_user_role ab_user_role_user_id_role_id_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_user_role
    ADD CONSTRAINT ab_user_role_user_id_role_id_key UNIQUE (user_id, role_id);


--
-- Name: ab_user ab_user_username_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_user
    ADD CONSTRAINT ab_user_username_key UNIQUE (username);


--
-- Name: ab_view_menu ab_view_menu_name_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_view_menu
    ADD CONSTRAINT ab_view_menu_name_key UNIQUE (name);


--
-- Name: ab_view_menu ab_view_menu_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_view_menu
    ADD CONSTRAINT ab_view_menu_pkey PRIMARY KEY (id);


--
-- Name: alembic_version alembic_version_pkc; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.alembic_version
    ADD CONSTRAINT alembic_version_pkc PRIMARY KEY (version_num);


--
-- Name: annotation_layer annotation_layer_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.annotation_layer
    ADD CONSTRAINT annotation_layer_pkey PRIMARY KEY (id);


--
-- Name: annotation annotation_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.annotation
    ADD CONSTRAINT annotation_pkey PRIMARY KEY (id);


--
-- Name: cache_keys cache_keys_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.cache_keys
    ADD CONSTRAINT cache_keys_pkey PRIMARY KEY (id);


--
-- Name: query client_id; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.query
    ADD CONSTRAINT client_id UNIQUE (client_id);


--
-- Name: companies companies_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_pkey PRIMARY KEY (id);


--
-- Name: css_templates css_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.css_templates
    ADD CONSTRAINT css_templates_pkey PRIMARY KEY (id);


--
-- Name: dashboard_roles dashboard_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_roles
    ADD CONSTRAINT dashboard_roles_pkey PRIMARY KEY (id);


--
-- Name: dashboard_slices dashboard_slices_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_slices
    ADD CONSTRAINT dashboard_slices_pkey PRIMARY KEY (id);


--
-- Name: dashboard_user dashboard_user_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_user
    ADD CONSTRAINT dashboard_user_pkey PRIMARY KEY (id);


--
-- Name: dashboards dashboards_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboards
    ADD CONSTRAINT dashboards_pkey PRIMARY KEY (id);


--
-- Name: database_user_oauth2_tokens database_user_oauth2_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.database_user_oauth2_tokens
    ADD CONSTRAINT database_user_oauth2_tokens_pkey PRIMARY KEY (id);


--
-- Name: dbs dbs_database_name_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dbs
    ADD CONSTRAINT dbs_database_name_key UNIQUE (database_name);


--
-- Name: dbs dbs_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dbs
    ADD CONSTRAINT dbs_pkey PRIMARY KEY (id);


--
-- Name: dbs dbs_verbose_name_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dbs
    ADD CONSTRAINT dbs_verbose_name_key UNIQUE (verbose_name);


--
-- Name: dynamic_plugin dynamic_plugin_key_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dynamic_plugin
    ADD CONSTRAINT dynamic_plugin_key_key UNIQUE (key);


--
-- Name: dynamic_plugin dynamic_plugin_name_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dynamic_plugin
    ADD CONSTRAINT dynamic_plugin_name_key UNIQUE (name);


--
-- Name: dynamic_plugin dynamic_plugin_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dynamic_plugin
    ADD CONSTRAINT dynamic_plugin_pkey PRIMARY KEY (id);


--
-- Name: favstar favstar_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.favstar
    ADD CONSTRAINT favstar_pkey PRIMARY KEY (id);


--
-- Name: dashboards idx_unique_slug; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboards
    ADD CONSTRAINT idx_unique_slug UNIQUE (slug);


--
-- Name: job_batches_new job_batches_new_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_new
    ADD CONSTRAINT job_batches_new_pkey PRIMARY KEY (id);


--
-- Name: job_batches_partitioned job_batches_partitioned_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned
    ADD CONSTRAINT job_batches_partitioned_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_batches_p2025_01 job_batches_p2025_01_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_p2025_01
    ADD CONSTRAINT job_batches_p2025_01_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_batches_p2025_02 job_batches_p2025_02_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_p2025_02
    ADD CONSTRAINT job_batches_p2025_02_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_batches_p2025_03 job_batches_p2025_03_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_p2025_03
    ADD CONSTRAINT job_batches_p2025_03_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_batches_p2025_04 job_batches_p2025_04_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_p2025_04
    ADD CONSTRAINT job_batches_p2025_04_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_batches_p2025_05 job_batches_p2025_05_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_p2025_05
    ADD CONSTRAINT job_batches_p2025_05_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_batches_p2025_06 job_batches_p2025_06_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_p2025_06
    ADD CONSTRAINT job_batches_p2025_06_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_batches_p2025_07 job_batches_p2025_07_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_p2025_07
    ADD CONSTRAINT job_batches_p2025_07_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_batches_p2025_08 job_batches_p2025_08_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_p2025_08
    ADD CONSTRAINT job_batches_p2025_08_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_batches_p2025_09 job_batches_p2025_09_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_p2025_09
    ADD CONSTRAINT job_batches_p2025_09_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_batches_p2025_10 job_batches_p2025_10_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_p2025_10
    ADD CONSTRAINT job_batches_p2025_10_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_batches_p2025_11 job_batches_p2025_11_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_p2025_11
    ADD CONSTRAINT job_batches_p2025_11_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_batches_p2025_12 job_batches_p2025_12_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_p2025_12
    ADD CONSTRAINT job_batches_p2025_12_pkey PRIMARY KEY (id, batch_date);


--
-- Name: job_categories job_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_categories
    ADD CONSTRAINT job_categories_pkey PRIMARY KEY (id);


--
-- Name: job_tags job_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_tags
    ADD CONSTRAINT job_tags_pkey PRIMARY KEY (id);


--
-- Name: jobs_partitioned jobs_partitioned_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_partitioned
    ADD CONSTRAINT jobs_partitioned_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2025_01 jobs_p2025_01_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2025_01
    ADD CONSTRAINT jobs_p2025_01_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2025_02 jobs_p2025_02_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2025_02
    ADD CONSTRAINT jobs_p2025_02_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2025_03 jobs_p2025_03_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2025_03
    ADD CONSTRAINT jobs_p2025_03_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2025_04 jobs_p2025_04_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2025_04
    ADD CONSTRAINT jobs_p2025_04_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2025_05 jobs_p2025_05_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2025_05
    ADD CONSTRAINT jobs_p2025_05_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2025_06 jobs_p2025_06_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2025_06
    ADD CONSTRAINT jobs_p2025_06_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2025_07 jobs_p2025_07_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2025_07
    ADD CONSTRAINT jobs_p2025_07_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2025_08 jobs_p2025_08_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2025_08
    ADD CONSTRAINT jobs_p2025_08_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2025_09 jobs_p2025_09_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2025_09
    ADD CONSTRAINT jobs_p2025_09_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2025_10 jobs_p2025_10_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2025_10
    ADD CONSTRAINT jobs_p2025_10_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2025_11 jobs_p2025_11_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2025_11
    ADD CONSTRAINT jobs_p2025_11_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2025_12 jobs_p2025_12_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2025_12
    ADD CONSTRAINT jobs_p2025_12_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2026_01 jobs_p2026_01_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2026_01
    ADD CONSTRAINT jobs_p2026_01_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2026_02 jobs_p2026_02_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2026_02
    ADD CONSTRAINT jobs_p2026_02_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2026_03 jobs_p2026_03_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2026_03
    ADD CONSTRAINT jobs_p2026_03_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2026_04 jobs_p2026_04_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2026_04
    ADD CONSTRAINT jobs_p2026_04_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2026_05 jobs_p2026_05_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2026_05
    ADD CONSTRAINT jobs_p2026_05_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2026_06 jobs_p2026_06_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2026_06
    ADD CONSTRAINT jobs_p2026_06_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2026_07 jobs_p2026_07_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2026_07
    ADD CONSTRAINT jobs_p2026_07_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2026_08 jobs_p2026_08_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2026_08
    ADD CONSTRAINT jobs_p2026_08_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2026_09 jobs_p2026_09_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2026_09
    ADD CONSTRAINT jobs_p2026_09_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2026_10 jobs_p2026_10_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2026_10
    ADD CONSTRAINT jobs_p2026_10_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2026_11 jobs_p2026_11_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2026_11
    ADD CONSTRAINT jobs_p2026_11_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2026_12 jobs_p2026_12_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2026_12
    ADD CONSTRAINT jobs_p2026_12_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2027_01 jobs_p2027_01_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2027_01
    ADD CONSTRAINT jobs_p2027_01_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2027_02 jobs_p2027_02_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2027_02
    ADD CONSTRAINT jobs_p2027_02_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2027_03 jobs_p2027_03_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2027_03
    ADD CONSTRAINT jobs_p2027_03_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2027_04 jobs_p2027_04_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2027_04
    ADD CONSTRAINT jobs_p2027_04_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2027_05 jobs_p2027_05_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2027_05
    ADD CONSTRAINT jobs_p2027_05_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2027_06 jobs_p2027_06_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2027_06
    ADD CONSTRAINT jobs_p2027_06_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2027_07 jobs_p2027_07_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2027_07
    ADD CONSTRAINT jobs_p2027_07_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2027_08 jobs_p2027_08_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2027_08
    ADD CONSTRAINT jobs_p2027_08_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2027_09 jobs_p2027_09_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2027_09
    ADD CONSTRAINT jobs_p2027_09_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2027_10 jobs_p2027_10_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2027_10
    ADD CONSTRAINT jobs_p2027_10_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2027_11 jobs_p2027_11_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2027_11
    ADD CONSTRAINT jobs_p2027_11_pkey PRIMARY KEY (id, created_at);


--
-- Name: jobs_p2027_12 jobs_p2027_12_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.jobs_p2027_12
    ADD CONSTRAINT jobs_p2027_12_pkey PRIMARY KEY (id, created_at);


--
-- Name: key_value key_value_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.key_value
    ADD CONSTRAINT key_value_pkey PRIMARY KEY (id);


--
-- Name: keyvalue keyvalue_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.keyvalue
    ADD CONSTRAINT keyvalue_pkey PRIMARY KEY (id);


--
-- Name: locations locations_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT locations_pkey PRIMARY KEY (id);


--
-- Name: logs logs_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.logs
    ADD CONSTRAINT logs_pkey PRIMARY KEY (id);


--
-- Name: query query_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.query
    ADD CONSTRAINT query_pkey PRIMARY KEY (id);


--
-- Name: report_execution_log report_execution_log_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_execution_log
    ADD CONSTRAINT report_execution_log_pkey PRIMARY KEY (id);


--
-- Name: report_recipient report_recipient_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_recipient
    ADD CONSTRAINT report_recipient_pkey PRIMARY KEY (id);


--
-- Name: report_schedule report_schedule_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_schedule
    ADD CONSTRAINT report_schedule_pkey PRIMARY KEY (id);


--
-- Name: report_schedule_user report_schedule_user_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_schedule_user
    ADD CONSTRAINT report_schedule_user_pkey PRIMARY KEY (id);


--
-- Name: rls_filter_roles rls_filter_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.rls_filter_roles
    ADD CONSTRAINT rls_filter_roles_pkey PRIMARY KEY (id);


--
-- Name: rls_filter_tables rls_filter_tables_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.rls_filter_tables
    ADD CONSTRAINT rls_filter_tables_pkey PRIMARY KEY (id);


--
-- Name: row_level_security_filters row_level_security_filters_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.row_level_security_filters
    ADD CONSTRAINT row_level_security_filters_pkey PRIMARY KEY (id);


--
-- Name: saved_query saved_query_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.saved_query
    ADD CONSTRAINT saved_query_pkey PRIMARY KEY (id);


--
-- Name: schema_version schema_version_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.schema_version
    ADD CONSTRAINT schema_version_pkey PRIMARY KEY (id);


--
-- Name: slice_user slice_user_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.slice_user
    ADD CONSTRAINT slice_user_pkey PRIMARY KEY (id);


--
-- Name: slices slices_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.slices
    ADD CONSTRAINT slices_pkey PRIMARY KEY (id);


--
-- Name: sql_metrics sql_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.sql_metrics
    ADD CONSTRAINT sql_metrics_pkey PRIMARY KEY (id);


--
-- Name: sqlatable_user sqlatable_user_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.sqlatable_user
    ADD CONSTRAINT sqlatable_user_pkey PRIMARY KEY (id);


--
-- Name: ssh_tunnels ssh_tunnels_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ssh_tunnels
    ADD CONSTRAINT ssh_tunnels_pkey PRIMARY KEY (id);


--
-- Name: tab_state tab_state_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tab_state
    ADD CONSTRAINT tab_state_pkey PRIMARY KEY (id);


--
-- Name: table_columns table_columns_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_columns
    ADD CONSTRAINT table_columns_pkey PRIMARY KEY (id);


--
-- Name: table_schema table_schema_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_schema
    ADD CONSTRAINT table_schema_pkey PRIMARY KEY (id);


--
-- Name: tables tables_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tables
    ADD CONSTRAINT tables_pkey PRIMARY KEY (id);


--
-- Name: tag tag_name_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tag
    ADD CONSTRAINT tag_name_key UNIQUE (name);


--
-- Name: tag tag_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tag
    ADD CONSTRAINT tag_pkey PRIMARY KEY (id);


--
-- Name: tagged_object tagged_object_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tagged_object
    ADD CONSTRAINT tagged_object_pkey PRIMARY KEY (id);


--
-- Name: tagged_object uix_tagged_object; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tagged_object
    ADD CONSTRAINT uix_tagged_object UNIQUE (tag_id, object_id, object_type);


--
-- Name: job_batches_new unique_batch_date_source; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_new
    ADD CONSTRAINT unique_batch_date_source UNIQUE (batch_date, source);


--
-- Name: job_categories unique_category_name; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_categories
    ADD CONSTRAINT unique_category_name UNIQUE (name);


--
-- Name: companies unique_company_name; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT unique_company_name UNIQUE (name);


--
-- Name: locations unique_location_name; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT unique_location_name UNIQUE (name);


--
-- Name: job_tags unique_tag_name; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_tags
    ADD CONSTRAINT unique_tag_name UNIQUE (name);


--
-- Name: work_types unique_work_type_name; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.work_types
    ADD CONSTRAINT unique_work_type_name UNIQUE (name);


--
-- Name: dashboard_slices uq_dashboard_slice; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_slices
    ADD CONSTRAINT uq_dashboard_slice UNIQUE (dashboard_id, slice_id);


--
-- Name: dashboards uq_dashboards_uuid; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboards
    ADD CONSTRAINT uq_dashboards_uuid UNIQUE (uuid);


--
-- Name: dbs uq_dbs_uuid; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dbs
    ADD CONSTRAINT uq_dbs_uuid UNIQUE (uuid);


--
-- Name: report_schedule uq_report_schedule_name_type; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_schedule
    ADD CONSTRAINT uq_report_schedule_name_type UNIQUE (name, type);


--
-- Name: row_level_security_filters uq_rls_name; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.row_level_security_filters
    ADD CONSTRAINT uq_rls_name UNIQUE (name);


--
-- Name: saved_query uq_saved_query_uuid; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.saved_query
    ADD CONSTRAINT uq_saved_query_uuid UNIQUE (uuid);


--
-- Name: slices uq_slices_uuid; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.slices
    ADD CONSTRAINT uq_slices_uuid UNIQUE (uuid);


--
-- Name: sql_metrics uq_sql_metrics_metric_name; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.sql_metrics
    ADD CONSTRAINT uq_sql_metrics_metric_name UNIQUE (metric_name, table_id);


--
-- Name: sql_metrics uq_sql_metrics_uuid; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.sql_metrics
    ADD CONSTRAINT uq_sql_metrics_uuid UNIQUE (uuid);


--
-- Name: table_columns uq_table_columns_column_name; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_columns
    ADD CONSTRAINT uq_table_columns_column_name UNIQUE (column_name, table_id);


--
-- Name: table_columns uq_table_columns_uuid; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_columns
    ADD CONSTRAINT uq_table_columns_uuid UNIQUE (uuid);


--
-- Name: tables uq_tables_uuid; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tables
    ADD CONSTRAINT uq_tables_uuid UNIQUE (uuid);


--
-- Name: user_attribute user_attribute_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.user_attribute
    ADD CONSTRAINT user_attribute_pkey PRIMARY KEY (id);


--
-- Name: work_types work_types_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.work_types
    ADD CONSTRAINT work_types_pkey PRIMARY KEY (id);


--
-- Name: idx_companies_name; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_companies_name ON public.companies USING btree (name);


--
-- Name: idx_job_batches_date; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_job_batches_date ON public.job_batches_new USING btree (batch_date);


--
-- Name: idx_job_batches_partitioned_date; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_job_batches_partitioned_date ON ONLY public.job_batches_partitioned USING btree (batch_date);


--
-- Name: idx_job_batches_partitioned_status; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_job_batches_partitioned_status ON ONLY public.job_batches_partitioned USING btree (status);


--
-- Name: idx_job_categories_name; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_job_categories_name ON public.job_categories USING btree (name);


--
-- Name: idx_job_tags_name; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_job_tags_name ON public.job_tags USING btree (name);


--
-- Name: idx_jobs_partitioned_company_id; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_jobs_partitioned_company_id ON ONLY public.jobs_partitioned USING btree (company_id);


--
-- Name: idx_jobs_partitioned_created_at; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_jobs_partitioned_created_at ON ONLY public.jobs_partitioned USING btree (created_at);


--
-- Name: idx_jobs_partitioned_job_batch_id; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_jobs_partitioned_job_batch_id ON ONLY public.jobs_partitioned USING btree (job_batch_id);


--
-- Name: idx_locations_name; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_locations_name ON public.locations USING btree (name);


--
-- Name: idx_user_id_database_id; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_user_id_database_id ON public.database_user_oauth2_tokens USING btree (user_id, database_id);


--
-- Name: idx_work_types_name; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_work_types_name ON public.work_types USING btree (name);


--
-- Name: ix_cache_keys_datasource_uid; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ix_cache_keys_datasource_uid ON public.cache_keys USING btree (datasource_uid);


--
-- Name: ix_creation_method; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ix_creation_method ON public.report_schedule USING btree (creation_method);


--
-- Name: ix_key_value_expires_on; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ix_key_value_expires_on ON public.key_value USING btree (expires_on);


--
-- Name: ix_key_value_uuid; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE UNIQUE INDEX ix_key_value_uuid ON public.key_value USING btree (uuid);


--
-- Name: ix_logs_user_id_dttm; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ix_logs_user_id_dttm ON public.logs USING btree (user_id, dttm);


--
-- Name: ix_query_results_key; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ix_query_results_key ON public.query USING btree (results_key);


--
-- Name: ix_report_execution_log_report_schedule_id; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ix_report_execution_log_report_schedule_id ON public.report_execution_log USING btree (report_schedule_id);


--
-- Name: ix_report_execution_log_start_dttm; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ix_report_execution_log_start_dttm ON public.report_execution_log USING btree (start_dttm);


--
-- Name: ix_report_recipient_report_schedule_id; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ix_report_recipient_report_schedule_id ON public.report_recipient USING btree (report_schedule_id);


--
-- Name: ix_report_schedule_active; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ix_report_schedule_active ON public.report_schedule USING btree (active);


--
-- Name: ix_row_level_security_filters_filter_type; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ix_row_level_security_filters_filter_type ON public.row_level_security_filters USING btree (filter_type);


--
-- Name: ix_sql_editor_id; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ix_sql_editor_id ON public.query USING btree (sql_editor_id);


--
-- Name: ix_ssh_tunnels_database_id; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE UNIQUE INDEX ix_ssh_tunnels_database_id ON public.ssh_tunnels USING btree (database_id);


--
-- Name: ix_ssh_tunnels_uuid; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE UNIQUE INDEX ix_ssh_tunnels_uuid ON public.ssh_tunnels USING btree (uuid);


--
-- Name: ix_tab_state_id; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE UNIQUE INDEX ix_tab_state_id ON public.tab_state USING btree (id);


--
-- Name: ix_table_schema_id; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE UNIQUE INDEX ix_table_schema_id ON public.table_schema USING btree (id);


--
-- Name: ix_tagged_object_object_id; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ix_tagged_object_object_id ON public.tagged_object USING btree (object_id);


--
-- Name: job_batches_p2025_01_batch_date_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_01_batch_date_idx ON public.job_batches_p2025_01 USING btree (batch_date);


--
-- Name: job_batches_p2025_01_status_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_01_status_idx ON public.job_batches_p2025_01 USING btree (status);


--
-- Name: job_batches_p2025_02_batch_date_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_02_batch_date_idx ON public.job_batches_p2025_02 USING btree (batch_date);


--
-- Name: job_batches_p2025_02_status_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_02_status_idx ON public.job_batches_p2025_02 USING btree (status);


--
-- Name: job_batches_p2025_03_batch_date_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_03_batch_date_idx ON public.job_batches_p2025_03 USING btree (batch_date);


--
-- Name: job_batches_p2025_03_status_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_03_status_idx ON public.job_batches_p2025_03 USING btree (status);


--
-- Name: job_batches_p2025_04_batch_date_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_04_batch_date_idx ON public.job_batches_p2025_04 USING btree (batch_date);


--
-- Name: job_batches_p2025_04_status_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_04_status_idx ON public.job_batches_p2025_04 USING btree (status);


--
-- Name: job_batches_p2025_05_batch_date_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_05_batch_date_idx ON public.job_batches_p2025_05 USING btree (batch_date);


--
-- Name: job_batches_p2025_05_status_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_05_status_idx ON public.job_batches_p2025_05 USING btree (status);


--
-- Name: job_batches_p2025_06_batch_date_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_06_batch_date_idx ON public.job_batches_p2025_06 USING btree (batch_date);


--
-- Name: job_batches_p2025_06_status_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_06_status_idx ON public.job_batches_p2025_06 USING btree (status);


--
-- Name: job_batches_p2025_07_batch_date_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_07_batch_date_idx ON public.job_batches_p2025_07 USING btree (batch_date);


--
-- Name: job_batches_p2025_07_status_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_07_status_idx ON public.job_batches_p2025_07 USING btree (status);


--
-- Name: job_batches_p2025_08_batch_date_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_08_batch_date_idx ON public.job_batches_p2025_08 USING btree (batch_date);


--
-- Name: job_batches_p2025_08_status_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_08_status_idx ON public.job_batches_p2025_08 USING btree (status);


--
-- Name: job_batches_p2025_09_batch_date_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_09_batch_date_idx ON public.job_batches_p2025_09 USING btree (batch_date);


--
-- Name: job_batches_p2025_09_status_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_09_status_idx ON public.job_batches_p2025_09 USING btree (status);


--
-- Name: job_batches_p2025_10_batch_date_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_10_batch_date_idx ON public.job_batches_p2025_10 USING btree (batch_date);


--
-- Name: job_batches_p2025_10_status_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_10_status_idx ON public.job_batches_p2025_10 USING btree (status);


--
-- Name: job_batches_p2025_11_batch_date_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_11_batch_date_idx ON public.job_batches_p2025_11 USING btree (batch_date);


--
-- Name: job_batches_p2025_11_status_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_11_status_idx ON public.job_batches_p2025_11 USING btree (status);


--
-- Name: job_batches_p2025_12_batch_date_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_12_batch_date_idx ON public.job_batches_p2025_12 USING btree (batch_date);


--
-- Name: job_batches_p2025_12_status_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX job_batches_p2025_12_status_idx ON public.job_batches_p2025_12 USING btree (status);


--
-- Name: jobs_p2025_01_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_01_company_id_idx ON public.jobs_p2025_01 USING btree (company_id);


--
-- Name: jobs_p2025_01_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_01_created_at_idx ON public.jobs_p2025_01 USING btree (created_at);


--
-- Name: jobs_p2025_01_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_01_job_batch_id_idx ON public.jobs_p2025_01 USING btree (job_batch_id);


--
-- Name: jobs_p2025_02_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_02_company_id_idx ON public.jobs_p2025_02 USING btree (company_id);


--
-- Name: jobs_p2025_02_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_02_created_at_idx ON public.jobs_p2025_02 USING btree (created_at);


--
-- Name: jobs_p2025_02_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_02_job_batch_id_idx ON public.jobs_p2025_02 USING btree (job_batch_id);


--
-- Name: jobs_p2025_03_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_03_company_id_idx ON public.jobs_p2025_03 USING btree (company_id);


--
-- Name: jobs_p2025_03_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_03_created_at_idx ON public.jobs_p2025_03 USING btree (created_at);


--
-- Name: jobs_p2025_03_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_03_job_batch_id_idx ON public.jobs_p2025_03 USING btree (job_batch_id);


--
-- Name: jobs_p2025_04_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_04_company_id_idx ON public.jobs_p2025_04 USING btree (company_id);


--
-- Name: jobs_p2025_04_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_04_created_at_idx ON public.jobs_p2025_04 USING btree (created_at);


--
-- Name: jobs_p2025_04_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_04_job_batch_id_idx ON public.jobs_p2025_04 USING btree (job_batch_id);


--
-- Name: jobs_p2025_05_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_05_company_id_idx ON public.jobs_p2025_05 USING btree (company_id);


--
-- Name: jobs_p2025_05_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_05_created_at_idx ON public.jobs_p2025_05 USING btree (created_at);


--
-- Name: jobs_p2025_05_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_05_job_batch_id_idx ON public.jobs_p2025_05 USING btree (job_batch_id);


--
-- Name: jobs_p2025_06_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_06_company_id_idx ON public.jobs_p2025_06 USING btree (company_id);


--
-- Name: jobs_p2025_06_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_06_created_at_idx ON public.jobs_p2025_06 USING btree (created_at);


--
-- Name: jobs_p2025_06_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_06_job_batch_id_idx ON public.jobs_p2025_06 USING btree (job_batch_id);


--
-- Name: jobs_p2025_07_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_07_company_id_idx ON public.jobs_p2025_07 USING btree (company_id);


--
-- Name: jobs_p2025_07_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_07_created_at_idx ON public.jobs_p2025_07 USING btree (created_at);


--
-- Name: jobs_p2025_07_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_07_job_batch_id_idx ON public.jobs_p2025_07 USING btree (job_batch_id);


--
-- Name: jobs_p2025_08_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_08_company_id_idx ON public.jobs_p2025_08 USING btree (company_id);


--
-- Name: jobs_p2025_08_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_08_created_at_idx ON public.jobs_p2025_08 USING btree (created_at);


--
-- Name: jobs_p2025_08_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_08_job_batch_id_idx ON public.jobs_p2025_08 USING btree (job_batch_id);


--
-- Name: jobs_p2025_09_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_09_company_id_idx ON public.jobs_p2025_09 USING btree (company_id);


--
-- Name: jobs_p2025_09_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_09_created_at_idx ON public.jobs_p2025_09 USING btree (created_at);


--
-- Name: jobs_p2025_09_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_09_job_batch_id_idx ON public.jobs_p2025_09 USING btree (job_batch_id);


--
-- Name: jobs_p2025_10_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_10_company_id_idx ON public.jobs_p2025_10 USING btree (company_id);


--
-- Name: jobs_p2025_10_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_10_created_at_idx ON public.jobs_p2025_10 USING btree (created_at);


--
-- Name: jobs_p2025_10_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_10_job_batch_id_idx ON public.jobs_p2025_10 USING btree (job_batch_id);


--
-- Name: jobs_p2025_11_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_11_company_id_idx ON public.jobs_p2025_11 USING btree (company_id);


--
-- Name: jobs_p2025_11_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_11_created_at_idx ON public.jobs_p2025_11 USING btree (created_at);


--
-- Name: jobs_p2025_11_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_11_job_batch_id_idx ON public.jobs_p2025_11 USING btree (job_batch_id);


--
-- Name: jobs_p2025_12_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_12_company_id_idx ON public.jobs_p2025_12 USING btree (company_id);


--
-- Name: jobs_p2025_12_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_12_created_at_idx ON public.jobs_p2025_12 USING btree (created_at);


--
-- Name: jobs_p2025_12_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2025_12_job_batch_id_idx ON public.jobs_p2025_12 USING btree (job_batch_id);


--
-- Name: jobs_p2026_01_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_01_company_id_idx ON public.jobs_p2026_01 USING btree (company_id);


--
-- Name: jobs_p2026_01_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_01_created_at_idx ON public.jobs_p2026_01 USING btree (created_at);


--
-- Name: jobs_p2026_01_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_01_job_batch_id_idx ON public.jobs_p2026_01 USING btree (job_batch_id);


--
-- Name: jobs_p2026_02_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_02_company_id_idx ON public.jobs_p2026_02 USING btree (company_id);


--
-- Name: jobs_p2026_02_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_02_created_at_idx ON public.jobs_p2026_02 USING btree (created_at);


--
-- Name: jobs_p2026_02_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_02_job_batch_id_idx ON public.jobs_p2026_02 USING btree (job_batch_id);


--
-- Name: jobs_p2026_03_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_03_company_id_idx ON public.jobs_p2026_03 USING btree (company_id);


--
-- Name: jobs_p2026_03_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_03_created_at_idx ON public.jobs_p2026_03 USING btree (created_at);


--
-- Name: jobs_p2026_03_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_03_job_batch_id_idx ON public.jobs_p2026_03 USING btree (job_batch_id);


--
-- Name: jobs_p2026_04_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_04_company_id_idx ON public.jobs_p2026_04 USING btree (company_id);


--
-- Name: jobs_p2026_04_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_04_created_at_idx ON public.jobs_p2026_04 USING btree (created_at);


--
-- Name: jobs_p2026_04_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_04_job_batch_id_idx ON public.jobs_p2026_04 USING btree (job_batch_id);


--
-- Name: jobs_p2026_05_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_05_company_id_idx ON public.jobs_p2026_05 USING btree (company_id);


--
-- Name: jobs_p2026_05_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_05_created_at_idx ON public.jobs_p2026_05 USING btree (created_at);


--
-- Name: jobs_p2026_05_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_05_job_batch_id_idx ON public.jobs_p2026_05 USING btree (job_batch_id);


--
-- Name: jobs_p2026_06_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_06_company_id_idx ON public.jobs_p2026_06 USING btree (company_id);


--
-- Name: jobs_p2026_06_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_06_created_at_idx ON public.jobs_p2026_06 USING btree (created_at);


--
-- Name: jobs_p2026_06_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_06_job_batch_id_idx ON public.jobs_p2026_06 USING btree (job_batch_id);


--
-- Name: jobs_p2026_07_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_07_company_id_idx ON public.jobs_p2026_07 USING btree (company_id);


--
-- Name: jobs_p2026_07_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_07_created_at_idx ON public.jobs_p2026_07 USING btree (created_at);


--
-- Name: jobs_p2026_07_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_07_job_batch_id_idx ON public.jobs_p2026_07 USING btree (job_batch_id);


--
-- Name: jobs_p2026_08_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_08_company_id_idx ON public.jobs_p2026_08 USING btree (company_id);


--
-- Name: jobs_p2026_08_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_08_created_at_idx ON public.jobs_p2026_08 USING btree (created_at);


--
-- Name: jobs_p2026_08_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_08_job_batch_id_idx ON public.jobs_p2026_08 USING btree (job_batch_id);


--
-- Name: jobs_p2026_09_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_09_company_id_idx ON public.jobs_p2026_09 USING btree (company_id);


--
-- Name: jobs_p2026_09_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_09_created_at_idx ON public.jobs_p2026_09 USING btree (created_at);


--
-- Name: jobs_p2026_09_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_09_job_batch_id_idx ON public.jobs_p2026_09 USING btree (job_batch_id);


--
-- Name: jobs_p2026_10_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_10_company_id_idx ON public.jobs_p2026_10 USING btree (company_id);


--
-- Name: jobs_p2026_10_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_10_created_at_idx ON public.jobs_p2026_10 USING btree (created_at);


--
-- Name: jobs_p2026_10_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_10_job_batch_id_idx ON public.jobs_p2026_10 USING btree (job_batch_id);


--
-- Name: jobs_p2026_11_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_11_company_id_idx ON public.jobs_p2026_11 USING btree (company_id);


--
-- Name: jobs_p2026_11_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_11_created_at_idx ON public.jobs_p2026_11 USING btree (created_at);


--
-- Name: jobs_p2026_11_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_11_job_batch_id_idx ON public.jobs_p2026_11 USING btree (job_batch_id);


--
-- Name: jobs_p2026_12_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_12_company_id_idx ON public.jobs_p2026_12 USING btree (company_id);


--
-- Name: jobs_p2026_12_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_12_created_at_idx ON public.jobs_p2026_12 USING btree (created_at);


--
-- Name: jobs_p2026_12_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2026_12_job_batch_id_idx ON public.jobs_p2026_12 USING btree (job_batch_id);


--
-- Name: jobs_p2027_01_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_01_company_id_idx ON public.jobs_p2027_01 USING btree (company_id);


--
-- Name: jobs_p2027_01_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_01_created_at_idx ON public.jobs_p2027_01 USING btree (created_at);


--
-- Name: jobs_p2027_01_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_01_job_batch_id_idx ON public.jobs_p2027_01 USING btree (job_batch_id);


--
-- Name: jobs_p2027_02_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_02_company_id_idx ON public.jobs_p2027_02 USING btree (company_id);


--
-- Name: jobs_p2027_02_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_02_created_at_idx ON public.jobs_p2027_02 USING btree (created_at);


--
-- Name: jobs_p2027_02_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_02_job_batch_id_idx ON public.jobs_p2027_02 USING btree (job_batch_id);


--
-- Name: jobs_p2027_03_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_03_company_id_idx ON public.jobs_p2027_03 USING btree (company_id);


--
-- Name: jobs_p2027_03_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_03_created_at_idx ON public.jobs_p2027_03 USING btree (created_at);


--
-- Name: jobs_p2027_03_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_03_job_batch_id_idx ON public.jobs_p2027_03 USING btree (job_batch_id);


--
-- Name: jobs_p2027_04_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_04_company_id_idx ON public.jobs_p2027_04 USING btree (company_id);


--
-- Name: jobs_p2027_04_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_04_created_at_idx ON public.jobs_p2027_04 USING btree (created_at);


--
-- Name: jobs_p2027_04_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_04_job_batch_id_idx ON public.jobs_p2027_04 USING btree (job_batch_id);


--
-- Name: jobs_p2027_05_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_05_company_id_idx ON public.jobs_p2027_05 USING btree (company_id);


--
-- Name: jobs_p2027_05_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_05_created_at_idx ON public.jobs_p2027_05 USING btree (created_at);


--
-- Name: jobs_p2027_05_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_05_job_batch_id_idx ON public.jobs_p2027_05 USING btree (job_batch_id);


--
-- Name: jobs_p2027_06_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_06_company_id_idx ON public.jobs_p2027_06 USING btree (company_id);


--
-- Name: jobs_p2027_06_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_06_created_at_idx ON public.jobs_p2027_06 USING btree (created_at);


--
-- Name: jobs_p2027_06_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_06_job_batch_id_idx ON public.jobs_p2027_06 USING btree (job_batch_id);


--
-- Name: jobs_p2027_07_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_07_company_id_idx ON public.jobs_p2027_07 USING btree (company_id);


--
-- Name: jobs_p2027_07_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_07_created_at_idx ON public.jobs_p2027_07 USING btree (created_at);


--
-- Name: jobs_p2027_07_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_07_job_batch_id_idx ON public.jobs_p2027_07 USING btree (job_batch_id);


--
-- Name: jobs_p2027_08_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_08_company_id_idx ON public.jobs_p2027_08 USING btree (company_id);


--
-- Name: jobs_p2027_08_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_08_created_at_idx ON public.jobs_p2027_08 USING btree (created_at);


--
-- Name: jobs_p2027_08_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_08_job_batch_id_idx ON public.jobs_p2027_08 USING btree (job_batch_id);


--
-- Name: jobs_p2027_09_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_09_company_id_idx ON public.jobs_p2027_09 USING btree (company_id);


--
-- Name: jobs_p2027_09_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_09_created_at_idx ON public.jobs_p2027_09 USING btree (created_at);


--
-- Name: jobs_p2027_09_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_09_job_batch_id_idx ON public.jobs_p2027_09 USING btree (job_batch_id);


--
-- Name: jobs_p2027_10_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_10_company_id_idx ON public.jobs_p2027_10 USING btree (company_id);


--
-- Name: jobs_p2027_10_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_10_created_at_idx ON public.jobs_p2027_10 USING btree (created_at);


--
-- Name: jobs_p2027_10_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_10_job_batch_id_idx ON public.jobs_p2027_10 USING btree (job_batch_id);


--
-- Name: jobs_p2027_11_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_11_company_id_idx ON public.jobs_p2027_11 USING btree (company_id);


--
-- Name: jobs_p2027_11_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_11_created_at_idx ON public.jobs_p2027_11 USING btree (created_at);


--
-- Name: jobs_p2027_11_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_11_job_batch_id_idx ON public.jobs_p2027_11 USING btree (job_batch_id);


--
-- Name: jobs_p2027_12_company_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_12_company_id_idx ON public.jobs_p2027_12 USING btree (company_id);


--
-- Name: jobs_p2027_12_created_at_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_12_created_at_idx ON public.jobs_p2027_12 USING btree (created_at);


--
-- Name: jobs_p2027_12_job_batch_id_idx; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX jobs_p2027_12_job_batch_id_idx ON public.jobs_p2027_12 USING btree (job_batch_id);


--
-- Name: ti_dag_state; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ti_dag_state ON public.annotation USING btree (layer_id, start_dttm, end_dttm);


--
-- Name: ti_user_id_changed_on; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX ti_user_id_changed_on ON public.query USING btree (user_id, changed_on);


--
-- Name: job_batches_p2025_01_batch_date_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_date ATTACH PARTITION public.job_batches_p2025_01_batch_date_idx;


--
-- Name: job_batches_p2025_01_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.job_batches_partitioned_pkey ATTACH PARTITION public.job_batches_p2025_01_pkey;


--
-- Name: job_batches_p2025_01_status_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_status ATTACH PARTITION public.job_batches_p2025_01_status_idx;


--
-- Name: job_batches_p2025_02_batch_date_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_date ATTACH PARTITION public.job_batches_p2025_02_batch_date_idx;


--
-- Name: job_batches_p2025_02_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.job_batches_partitioned_pkey ATTACH PARTITION public.job_batches_p2025_02_pkey;


--
-- Name: job_batches_p2025_02_status_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_status ATTACH PARTITION public.job_batches_p2025_02_status_idx;


--
-- Name: job_batches_p2025_03_batch_date_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_date ATTACH PARTITION public.job_batches_p2025_03_batch_date_idx;


--
-- Name: job_batches_p2025_03_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.job_batches_partitioned_pkey ATTACH PARTITION public.job_batches_p2025_03_pkey;


--
-- Name: job_batches_p2025_03_status_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_status ATTACH PARTITION public.job_batches_p2025_03_status_idx;


--
-- Name: job_batches_p2025_04_batch_date_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_date ATTACH PARTITION public.job_batches_p2025_04_batch_date_idx;


--
-- Name: job_batches_p2025_04_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.job_batches_partitioned_pkey ATTACH PARTITION public.job_batches_p2025_04_pkey;


--
-- Name: job_batches_p2025_04_status_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_status ATTACH PARTITION public.job_batches_p2025_04_status_idx;


--
-- Name: job_batches_p2025_05_batch_date_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_date ATTACH PARTITION public.job_batches_p2025_05_batch_date_idx;


--
-- Name: job_batches_p2025_05_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.job_batches_partitioned_pkey ATTACH PARTITION public.job_batches_p2025_05_pkey;


--
-- Name: job_batches_p2025_05_status_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_status ATTACH PARTITION public.job_batches_p2025_05_status_idx;


--
-- Name: job_batches_p2025_06_batch_date_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_date ATTACH PARTITION public.job_batches_p2025_06_batch_date_idx;


--
-- Name: job_batches_p2025_06_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.job_batches_partitioned_pkey ATTACH PARTITION public.job_batches_p2025_06_pkey;


--
-- Name: job_batches_p2025_06_status_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_status ATTACH PARTITION public.job_batches_p2025_06_status_idx;


--
-- Name: job_batches_p2025_07_batch_date_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_date ATTACH PARTITION public.job_batches_p2025_07_batch_date_idx;


--
-- Name: job_batches_p2025_07_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.job_batches_partitioned_pkey ATTACH PARTITION public.job_batches_p2025_07_pkey;


--
-- Name: job_batches_p2025_07_status_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_status ATTACH PARTITION public.job_batches_p2025_07_status_idx;


--
-- Name: job_batches_p2025_08_batch_date_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_date ATTACH PARTITION public.job_batches_p2025_08_batch_date_idx;


--
-- Name: job_batches_p2025_08_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.job_batches_partitioned_pkey ATTACH PARTITION public.job_batches_p2025_08_pkey;


--
-- Name: job_batches_p2025_08_status_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_status ATTACH PARTITION public.job_batches_p2025_08_status_idx;


--
-- Name: job_batches_p2025_09_batch_date_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_date ATTACH PARTITION public.job_batches_p2025_09_batch_date_idx;


--
-- Name: job_batches_p2025_09_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.job_batches_partitioned_pkey ATTACH PARTITION public.job_batches_p2025_09_pkey;


--
-- Name: job_batches_p2025_09_status_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_status ATTACH PARTITION public.job_batches_p2025_09_status_idx;


--
-- Name: job_batches_p2025_10_batch_date_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_date ATTACH PARTITION public.job_batches_p2025_10_batch_date_idx;


--
-- Name: job_batches_p2025_10_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.job_batches_partitioned_pkey ATTACH PARTITION public.job_batches_p2025_10_pkey;


--
-- Name: job_batches_p2025_10_status_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_status ATTACH PARTITION public.job_batches_p2025_10_status_idx;


--
-- Name: job_batches_p2025_11_batch_date_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_date ATTACH PARTITION public.job_batches_p2025_11_batch_date_idx;


--
-- Name: job_batches_p2025_11_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.job_batches_partitioned_pkey ATTACH PARTITION public.job_batches_p2025_11_pkey;


--
-- Name: job_batches_p2025_11_status_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_status ATTACH PARTITION public.job_batches_p2025_11_status_idx;


--
-- Name: job_batches_p2025_12_batch_date_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_date ATTACH PARTITION public.job_batches_p2025_12_batch_date_idx;


--
-- Name: job_batches_p2025_12_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.job_batches_partitioned_pkey ATTACH PARTITION public.job_batches_p2025_12_pkey;


--
-- Name: job_batches_p2025_12_status_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_job_batches_partitioned_status ATTACH PARTITION public.job_batches_p2025_12_status_idx;


--
-- Name: jobs_p2025_01_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2025_01_company_id_idx;


--
-- Name: jobs_p2025_01_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2025_01_created_at_idx;


--
-- Name: jobs_p2025_01_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2025_01_job_batch_id_idx;


--
-- Name: jobs_p2025_01_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2025_01_pkey;


--
-- Name: jobs_p2025_02_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2025_02_company_id_idx;


--
-- Name: jobs_p2025_02_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2025_02_created_at_idx;


--
-- Name: jobs_p2025_02_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2025_02_job_batch_id_idx;


--
-- Name: jobs_p2025_02_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2025_02_pkey;


--
-- Name: jobs_p2025_03_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2025_03_company_id_idx;


--
-- Name: jobs_p2025_03_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2025_03_created_at_idx;


--
-- Name: jobs_p2025_03_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2025_03_job_batch_id_idx;


--
-- Name: jobs_p2025_03_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2025_03_pkey;


--
-- Name: jobs_p2025_04_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2025_04_company_id_idx;


--
-- Name: jobs_p2025_04_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2025_04_created_at_idx;


--
-- Name: jobs_p2025_04_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2025_04_job_batch_id_idx;


--
-- Name: jobs_p2025_04_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2025_04_pkey;


--
-- Name: jobs_p2025_05_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2025_05_company_id_idx;


--
-- Name: jobs_p2025_05_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2025_05_created_at_idx;


--
-- Name: jobs_p2025_05_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2025_05_job_batch_id_idx;


--
-- Name: jobs_p2025_05_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2025_05_pkey;


--
-- Name: jobs_p2025_06_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2025_06_company_id_idx;


--
-- Name: jobs_p2025_06_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2025_06_created_at_idx;


--
-- Name: jobs_p2025_06_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2025_06_job_batch_id_idx;


--
-- Name: jobs_p2025_06_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2025_06_pkey;


--
-- Name: jobs_p2025_07_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2025_07_company_id_idx;


--
-- Name: jobs_p2025_07_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2025_07_created_at_idx;


--
-- Name: jobs_p2025_07_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2025_07_job_batch_id_idx;


--
-- Name: jobs_p2025_07_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2025_07_pkey;


--
-- Name: jobs_p2025_08_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2025_08_company_id_idx;


--
-- Name: jobs_p2025_08_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2025_08_created_at_idx;


--
-- Name: jobs_p2025_08_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2025_08_job_batch_id_idx;


--
-- Name: jobs_p2025_08_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2025_08_pkey;


--
-- Name: jobs_p2025_09_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2025_09_company_id_idx;


--
-- Name: jobs_p2025_09_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2025_09_created_at_idx;


--
-- Name: jobs_p2025_09_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2025_09_job_batch_id_idx;


--
-- Name: jobs_p2025_09_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2025_09_pkey;


--
-- Name: jobs_p2025_10_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2025_10_company_id_idx;


--
-- Name: jobs_p2025_10_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2025_10_created_at_idx;


--
-- Name: jobs_p2025_10_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2025_10_job_batch_id_idx;


--
-- Name: jobs_p2025_10_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2025_10_pkey;


--
-- Name: jobs_p2025_11_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2025_11_company_id_idx;


--
-- Name: jobs_p2025_11_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2025_11_created_at_idx;


--
-- Name: jobs_p2025_11_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2025_11_job_batch_id_idx;


--
-- Name: jobs_p2025_11_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2025_11_pkey;


--
-- Name: jobs_p2025_12_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2025_12_company_id_idx;


--
-- Name: jobs_p2025_12_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2025_12_created_at_idx;


--
-- Name: jobs_p2025_12_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2025_12_job_batch_id_idx;


--
-- Name: jobs_p2025_12_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2025_12_pkey;


--
-- Name: jobs_p2026_01_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2026_01_company_id_idx;


--
-- Name: jobs_p2026_01_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2026_01_created_at_idx;


--
-- Name: jobs_p2026_01_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2026_01_job_batch_id_idx;


--
-- Name: jobs_p2026_01_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2026_01_pkey;


--
-- Name: jobs_p2026_02_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2026_02_company_id_idx;


--
-- Name: jobs_p2026_02_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2026_02_created_at_idx;


--
-- Name: jobs_p2026_02_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2026_02_job_batch_id_idx;


--
-- Name: jobs_p2026_02_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2026_02_pkey;


--
-- Name: jobs_p2026_03_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2026_03_company_id_idx;


--
-- Name: jobs_p2026_03_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2026_03_created_at_idx;


--
-- Name: jobs_p2026_03_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2026_03_job_batch_id_idx;


--
-- Name: jobs_p2026_03_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2026_03_pkey;


--
-- Name: jobs_p2026_04_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2026_04_company_id_idx;


--
-- Name: jobs_p2026_04_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2026_04_created_at_idx;


--
-- Name: jobs_p2026_04_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2026_04_job_batch_id_idx;


--
-- Name: jobs_p2026_04_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2026_04_pkey;


--
-- Name: jobs_p2026_05_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2026_05_company_id_idx;


--
-- Name: jobs_p2026_05_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2026_05_created_at_idx;


--
-- Name: jobs_p2026_05_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2026_05_job_batch_id_idx;


--
-- Name: jobs_p2026_05_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2026_05_pkey;


--
-- Name: jobs_p2026_06_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2026_06_company_id_idx;


--
-- Name: jobs_p2026_06_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2026_06_created_at_idx;


--
-- Name: jobs_p2026_06_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2026_06_job_batch_id_idx;


--
-- Name: jobs_p2026_06_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2026_06_pkey;


--
-- Name: jobs_p2026_07_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2026_07_company_id_idx;


--
-- Name: jobs_p2026_07_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2026_07_created_at_idx;


--
-- Name: jobs_p2026_07_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2026_07_job_batch_id_idx;


--
-- Name: jobs_p2026_07_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2026_07_pkey;


--
-- Name: jobs_p2026_08_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2026_08_company_id_idx;


--
-- Name: jobs_p2026_08_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2026_08_created_at_idx;


--
-- Name: jobs_p2026_08_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2026_08_job_batch_id_idx;


--
-- Name: jobs_p2026_08_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2026_08_pkey;


--
-- Name: jobs_p2026_09_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2026_09_company_id_idx;


--
-- Name: jobs_p2026_09_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2026_09_created_at_idx;


--
-- Name: jobs_p2026_09_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2026_09_job_batch_id_idx;


--
-- Name: jobs_p2026_09_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2026_09_pkey;


--
-- Name: jobs_p2026_10_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2026_10_company_id_idx;


--
-- Name: jobs_p2026_10_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2026_10_created_at_idx;


--
-- Name: jobs_p2026_10_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2026_10_job_batch_id_idx;


--
-- Name: jobs_p2026_10_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2026_10_pkey;


--
-- Name: jobs_p2026_11_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2026_11_company_id_idx;


--
-- Name: jobs_p2026_11_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2026_11_created_at_idx;


--
-- Name: jobs_p2026_11_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2026_11_job_batch_id_idx;


--
-- Name: jobs_p2026_11_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2026_11_pkey;


--
-- Name: jobs_p2026_12_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2026_12_company_id_idx;


--
-- Name: jobs_p2026_12_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2026_12_created_at_idx;


--
-- Name: jobs_p2026_12_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2026_12_job_batch_id_idx;


--
-- Name: jobs_p2026_12_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2026_12_pkey;


--
-- Name: jobs_p2027_01_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2027_01_company_id_idx;


--
-- Name: jobs_p2027_01_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2027_01_created_at_idx;


--
-- Name: jobs_p2027_01_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2027_01_job_batch_id_idx;


--
-- Name: jobs_p2027_01_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2027_01_pkey;


--
-- Name: jobs_p2027_02_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2027_02_company_id_idx;


--
-- Name: jobs_p2027_02_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2027_02_created_at_idx;


--
-- Name: jobs_p2027_02_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2027_02_job_batch_id_idx;


--
-- Name: jobs_p2027_02_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2027_02_pkey;


--
-- Name: jobs_p2027_03_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2027_03_company_id_idx;


--
-- Name: jobs_p2027_03_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2027_03_created_at_idx;


--
-- Name: jobs_p2027_03_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2027_03_job_batch_id_idx;


--
-- Name: jobs_p2027_03_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2027_03_pkey;


--
-- Name: jobs_p2027_04_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2027_04_company_id_idx;


--
-- Name: jobs_p2027_04_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2027_04_created_at_idx;


--
-- Name: jobs_p2027_04_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2027_04_job_batch_id_idx;


--
-- Name: jobs_p2027_04_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2027_04_pkey;


--
-- Name: jobs_p2027_05_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2027_05_company_id_idx;


--
-- Name: jobs_p2027_05_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2027_05_created_at_idx;


--
-- Name: jobs_p2027_05_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2027_05_job_batch_id_idx;


--
-- Name: jobs_p2027_05_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2027_05_pkey;


--
-- Name: jobs_p2027_06_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2027_06_company_id_idx;


--
-- Name: jobs_p2027_06_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2027_06_created_at_idx;


--
-- Name: jobs_p2027_06_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2027_06_job_batch_id_idx;


--
-- Name: jobs_p2027_06_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2027_06_pkey;


--
-- Name: jobs_p2027_07_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2027_07_company_id_idx;


--
-- Name: jobs_p2027_07_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2027_07_created_at_idx;


--
-- Name: jobs_p2027_07_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2027_07_job_batch_id_idx;


--
-- Name: jobs_p2027_07_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2027_07_pkey;


--
-- Name: jobs_p2027_08_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2027_08_company_id_idx;


--
-- Name: jobs_p2027_08_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2027_08_created_at_idx;


--
-- Name: jobs_p2027_08_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2027_08_job_batch_id_idx;


--
-- Name: jobs_p2027_08_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2027_08_pkey;


--
-- Name: jobs_p2027_09_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2027_09_company_id_idx;


--
-- Name: jobs_p2027_09_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2027_09_created_at_idx;


--
-- Name: jobs_p2027_09_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2027_09_job_batch_id_idx;


--
-- Name: jobs_p2027_09_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2027_09_pkey;


--
-- Name: jobs_p2027_10_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2027_10_company_id_idx;


--
-- Name: jobs_p2027_10_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2027_10_created_at_idx;


--
-- Name: jobs_p2027_10_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2027_10_job_batch_id_idx;


--
-- Name: jobs_p2027_10_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2027_10_pkey;


--
-- Name: jobs_p2027_11_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2027_11_company_id_idx;


--
-- Name: jobs_p2027_11_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2027_11_created_at_idx;


--
-- Name: jobs_p2027_11_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2027_11_job_batch_id_idx;


--
-- Name: jobs_p2027_11_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2027_11_pkey;


--
-- Name: jobs_p2027_12_company_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_company_id ATTACH PARTITION public.jobs_p2027_12_company_id_idx;


--
-- Name: jobs_p2027_12_created_at_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_created_at ATTACH PARTITION public.jobs_p2027_12_created_at_idx;


--
-- Name: jobs_p2027_12_job_batch_id_idx; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.idx_jobs_partitioned_job_batch_id ATTACH PARTITION public.jobs_p2027_12_job_batch_id_idx;


--
-- Name: jobs_p2027_12_pkey; Type: INDEX ATTACH; Schema: public; Owner: jobuser
--

ALTER INDEX public.jobs_partitioned_pkey ATTACH PARTITION public.jobs_p2027_12_pkey;


--
-- Name: jobs_partitioned before_insert_jobs_partitioned; Type: TRIGGER; Schema: public; Owner: jobuser
--

CREATE TRIGGER before_insert_jobs_partitioned BEFORE INSERT ON public.jobs_partitioned FOR EACH ROW EXECUTE FUNCTION public.create_new_partition_trigger();


--
-- Name: jobs_view jobs_view_delete; Type: TRIGGER; Schema: public; Owner: jobuser
--

CREATE TRIGGER jobs_view_delete INSTEAD OF DELETE ON public.jobs_view FOR EACH ROW EXECUTE FUNCTION public.jobs_view_delete_trigger();


--
-- Name: jobs_view jobs_view_insert; Type: TRIGGER; Schema: public; Owner: jobuser
--

CREATE TRIGGER jobs_view_insert INSTEAD OF INSERT ON public.jobs_view FOR EACH ROW EXECUTE FUNCTION public.jobs_view_insert_trigger();


--
-- Name: jobs_view jobs_view_update; Type: TRIGGER; Schema: public; Owner: jobuser
--

CREATE TRIGGER jobs_view_update INSTEAD OF UPDATE ON public.jobs_view FOR EACH ROW EXECUTE FUNCTION public.jobs_view_update_trigger();


--
-- Name: companies update_companies_updated_at; Type: TRIGGER; Schema: public; Owner: jobuser
--

CREATE TRIGGER update_companies_updated_at BEFORE UPDATE ON public.companies FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: ab_permission_view ab_permission_view_permission_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_permission_view
    ADD CONSTRAINT ab_permission_view_permission_id_fkey FOREIGN KEY (permission_id) REFERENCES public.ab_permission(id);


--
-- Name: ab_permission_view_role ab_permission_view_role_permission_view_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_permission_view_role
    ADD CONSTRAINT ab_permission_view_role_permission_view_id_fkey FOREIGN KEY (permission_view_id) REFERENCES public.ab_permission_view(id);


--
-- Name: ab_permission_view_role ab_permission_view_role_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_permission_view_role
    ADD CONSTRAINT ab_permission_view_role_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.ab_role(id);


--
-- Name: ab_permission_view ab_permission_view_view_menu_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_permission_view
    ADD CONSTRAINT ab_permission_view_view_menu_id_fkey FOREIGN KEY (view_menu_id) REFERENCES public.ab_view_menu(id);


--
-- Name: ab_user ab_user_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_user
    ADD CONSTRAINT ab_user_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: ab_user ab_user_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_user
    ADD CONSTRAINT ab_user_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: ab_user_role ab_user_role_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_user_role
    ADD CONSTRAINT ab_user_role_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.ab_role(id);


--
-- Name: ab_user_role ab_user_role_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ab_user_role
    ADD CONSTRAINT ab_user_role_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.ab_user(id);


--
-- Name: annotation annotation_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.annotation
    ADD CONSTRAINT annotation_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: annotation annotation_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.annotation
    ADD CONSTRAINT annotation_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: annotation_layer annotation_layer_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.annotation_layer
    ADD CONSTRAINT annotation_layer_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: annotation_layer annotation_layer_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.annotation_layer
    ADD CONSTRAINT annotation_layer_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: annotation annotation_layer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.annotation
    ADD CONSTRAINT annotation_layer_id_fkey FOREIGN KEY (layer_id) REFERENCES public.annotation_layer(id);


--
-- Name: css_templates css_templates_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.css_templates
    ADD CONSTRAINT css_templates_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: css_templates css_templates_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.css_templates
    ADD CONSTRAINT css_templates_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: dashboards dashboards_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboards
    ADD CONSTRAINT dashboards_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: dashboards dashboards_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboards
    ADD CONSTRAINT dashboards_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: database_user_oauth2_tokens database_user_oauth2_tokens_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.database_user_oauth2_tokens
    ADD CONSTRAINT database_user_oauth2_tokens_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: database_user_oauth2_tokens database_user_oauth2_tokens_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.database_user_oauth2_tokens
    ADD CONSTRAINT database_user_oauth2_tokens_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: database_user_oauth2_tokens database_user_oauth2_tokens_database_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.database_user_oauth2_tokens
    ADD CONSTRAINT database_user_oauth2_tokens_database_id_fkey FOREIGN KEY (database_id) REFERENCES public.dbs(id) ON DELETE CASCADE;


--
-- Name: database_user_oauth2_tokens database_user_oauth2_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.database_user_oauth2_tokens
    ADD CONSTRAINT database_user_oauth2_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.ab_user(id) ON DELETE CASCADE;


--
-- Name: dbs dbs_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dbs
    ADD CONSTRAINT dbs_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: dbs dbs_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dbs
    ADD CONSTRAINT dbs_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: dynamic_plugin dynamic_plugin_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dynamic_plugin
    ADD CONSTRAINT dynamic_plugin_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: dynamic_plugin dynamic_plugin_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dynamic_plugin
    ADD CONSTRAINT dynamic_plugin_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: favstar favstar_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.favstar
    ADD CONSTRAINT favstar_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.ab_user(id);


--
-- Name: dashboard_roles fk_dashboard_roles_dashboard_id_dashboards; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_roles
    ADD CONSTRAINT fk_dashboard_roles_dashboard_id_dashboards FOREIGN KEY (dashboard_id) REFERENCES public.dashboards(id) ON DELETE CASCADE;


--
-- Name: dashboard_roles fk_dashboard_roles_role_id_ab_role; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_roles
    ADD CONSTRAINT fk_dashboard_roles_role_id_ab_role FOREIGN KEY (role_id) REFERENCES public.ab_role(id) ON DELETE CASCADE;


--
-- Name: dashboard_slices fk_dashboard_slices_dashboard_id_dashboards; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_slices
    ADD CONSTRAINT fk_dashboard_slices_dashboard_id_dashboards FOREIGN KEY (dashboard_id) REFERENCES public.dashboards(id) ON DELETE CASCADE;


--
-- Name: dashboard_slices fk_dashboard_slices_slice_id_slices; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_slices
    ADD CONSTRAINT fk_dashboard_slices_slice_id_slices FOREIGN KEY (slice_id) REFERENCES public.slices(id) ON DELETE CASCADE;


--
-- Name: dashboard_user fk_dashboard_user_dashboard_id_dashboards; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_user
    ADD CONSTRAINT fk_dashboard_user_dashboard_id_dashboards FOREIGN KEY (dashboard_id) REFERENCES public.dashboards(id) ON DELETE CASCADE;


--
-- Name: dashboard_user fk_dashboard_user_user_id_ab_user; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.dashboard_user
    ADD CONSTRAINT fk_dashboard_user_user_id_ab_user FOREIGN KEY (user_id) REFERENCES public.ab_user(id) ON DELETE CASCADE;


--
-- Name: embedded_dashboards fk_embedded_dashboards_dashboard_id_dashboards; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.embedded_dashboards
    ADD CONSTRAINT fk_embedded_dashboards_dashboard_id_dashboards FOREIGN KEY (dashboard_id) REFERENCES public.dashboards(id) ON DELETE CASCADE;


--
-- Name: report_schedule_user fk_report_schedule_user_report_schedule_id_report_schedule; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_schedule_user
    ADD CONSTRAINT fk_report_schedule_user_report_schedule_id_report_schedule FOREIGN KEY (report_schedule_id) REFERENCES public.report_schedule(id) ON DELETE CASCADE;


--
-- Name: report_schedule_user fk_report_schedule_user_user_id_ab_user; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_schedule_user
    ADD CONSTRAINT fk_report_schedule_user_user_id_ab_user FOREIGN KEY (user_id) REFERENCES public.ab_user(id) ON DELETE CASCADE;


--
-- Name: slice_user fk_slice_user_slice_id_slices; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.slice_user
    ADD CONSTRAINT fk_slice_user_slice_id_slices FOREIGN KEY (slice_id) REFERENCES public.slices(id) ON DELETE CASCADE;


--
-- Name: slice_user fk_slice_user_user_id_ab_user; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.slice_user
    ADD CONSTRAINT fk_slice_user_user_id_ab_user FOREIGN KEY (user_id) REFERENCES public.ab_user(id) ON DELETE CASCADE;


--
-- Name: sql_metrics fk_sql_metrics_table_id_tables; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.sql_metrics
    ADD CONSTRAINT fk_sql_metrics_table_id_tables FOREIGN KEY (table_id) REFERENCES public.tables(id) ON DELETE CASCADE;


--
-- Name: sqlatable_user fk_sqlatable_user_table_id_tables; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.sqlatable_user
    ADD CONSTRAINT fk_sqlatable_user_table_id_tables FOREIGN KEY (table_id) REFERENCES public.tables(id) ON DELETE CASCADE;


--
-- Name: sqlatable_user fk_sqlatable_user_user_id_ab_user; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.sqlatable_user
    ADD CONSTRAINT fk_sqlatable_user_user_id_ab_user FOREIGN KEY (user_id) REFERENCES public.ab_user(id) ON DELETE CASCADE;


--
-- Name: table_columns fk_table_columns_table_id_tables; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_columns
    ADD CONSTRAINT fk_table_columns_table_id_tables FOREIGN KEY (table_id) REFERENCES public.tables(id) ON DELETE CASCADE;


--
-- Name: jobs_partitioned jobs_partitioned_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE public.jobs_partitioned
    ADD CONSTRAINT jobs_partitioned_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


--
-- Name: key_value key_value_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.key_value
    ADD CONSTRAINT key_value_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: key_value key_value_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.key_value
    ADD CONSTRAINT key_value_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: logs logs_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.logs
    ADD CONSTRAINT logs_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.ab_user(id);


--
-- Name: query query_database_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.query
    ADD CONSTRAINT query_database_id_fkey FOREIGN KEY (database_id) REFERENCES public.dbs(id);


--
-- Name: query query_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.query
    ADD CONSTRAINT query_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.ab_user(id);


--
-- Name: report_execution_log report_execution_log_report_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_execution_log
    ADD CONSTRAINT report_execution_log_report_schedule_id_fkey FOREIGN KEY (report_schedule_id) REFERENCES public.report_schedule(id);


--
-- Name: report_recipient report_recipient_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_recipient
    ADD CONSTRAINT report_recipient_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: report_recipient report_recipient_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_recipient
    ADD CONSTRAINT report_recipient_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: report_recipient report_recipient_report_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_recipient
    ADD CONSTRAINT report_recipient_report_schedule_id_fkey FOREIGN KEY (report_schedule_id) REFERENCES public.report_schedule(id);


--
-- Name: report_schedule report_schedule_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_schedule
    ADD CONSTRAINT report_schedule_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: report_schedule report_schedule_chart_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_schedule
    ADD CONSTRAINT report_schedule_chart_id_fkey FOREIGN KEY (chart_id) REFERENCES public.slices(id);


--
-- Name: report_schedule report_schedule_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_schedule
    ADD CONSTRAINT report_schedule_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: report_schedule report_schedule_dashboard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_schedule
    ADD CONSTRAINT report_schedule_dashboard_id_fkey FOREIGN KEY (dashboard_id) REFERENCES public.dashboards(id);


--
-- Name: report_schedule report_schedule_database_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.report_schedule
    ADD CONSTRAINT report_schedule_database_id_fkey FOREIGN KEY (database_id) REFERENCES public.dbs(id);


--
-- Name: rls_filter_roles rls_filter_roles_rls_filter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.rls_filter_roles
    ADD CONSTRAINT rls_filter_roles_rls_filter_id_fkey FOREIGN KEY (rls_filter_id) REFERENCES public.row_level_security_filters(id);


--
-- Name: rls_filter_roles rls_filter_roles_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.rls_filter_roles
    ADD CONSTRAINT rls_filter_roles_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.ab_role(id);


--
-- Name: rls_filter_tables rls_filter_tables_rls_filter_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.rls_filter_tables
    ADD CONSTRAINT rls_filter_tables_rls_filter_id_fkey FOREIGN KEY (rls_filter_id) REFERENCES public.row_level_security_filters(id);


--
-- Name: rls_filter_tables rls_filter_tables_table_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.rls_filter_tables
    ADD CONSTRAINT rls_filter_tables_table_id_fkey FOREIGN KEY (table_id) REFERENCES public.tables(id);


--
-- Name: row_level_security_filters row_level_security_filters_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.row_level_security_filters
    ADD CONSTRAINT row_level_security_filters_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: row_level_security_filters row_level_security_filters_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.row_level_security_filters
    ADD CONSTRAINT row_level_security_filters_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: saved_query saved_query_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.saved_query
    ADD CONSTRAINT saved_query_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: saved_query saved_query_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.saved_query
    ADD CONSTRAINT saved_query_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: saved_query saved_query_db_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.saved_query
    ADD CONSTRAINT saved_query_db_id_fkey FOREIGN KEY (db_id) REFERENCES public.dbs(id);


--
-- Name: tab_state saved_query_id; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tab_state
    ADD CONSTRAINT saved_query_id FOREIGN KEY (saved_query_id) REFERENCES public.saved_query(id) ON DELETE SET NULL;


--
-- Name: saved_query saved_query_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.saved_query
    ADD CONSTRAINT saved_query_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.ab_user(id);


--
-- Name: slices slices_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.slices
    ADD CONSTRAINT slices_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: slices slices_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.slices
    ADD CONSTRAINT slices_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: slices slices_last_saved_by_fk; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.slices
    ADD CONSTRAINT slices_last_saved_by_fk FOREIGN KEY (last_saved_by_fk) REFERENCES public.ab_user(id);


--
-- Name: sql_metrics sql_metrics_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.sql_metrics
    ADD CONSTRAINT sql_metrics_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: sql_metrics sql_metrics_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.sql_metrics
    ADD CONSTRAINT sql_metrics_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: ssh_tunnels ssh_tunnels_database_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.ssh_tunnels
    ADD CONSTRAINT ssh_tunnels_database_id_fkey FOREIGN KEY (database_id) REFERENCES public.dbs(id);


--
-- Name: tab_state tab_state_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tab_state
    ADD CONSTRAINT tab_state_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: tab_state tab_state_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tab_state
    ADD CONSTRAINT tab_state_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: tab_state tab_state_database_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tab_state
    ADD CONSTRAINT tab_state_database_id_fkey FOREIGN KEY (database_id) REFERENCES public.dbs(id) ON DELETE CASCADE;


--
-- Name: tab_state tab_state_latest_query_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tab_state
    ADD CONSTRAINT tab_state_latest_query_id_fkey FOREIGN KEY (latest_query_id) REFERENCES public.query(client_id) ON DELETE SET NULL;


--
-- Name: tab_state tab_state_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tab_state
    ADD CONSTRAINT tab_state_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.ab_user(id);


--
-- Name: table_columns table_columns_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_columns
    ADD CONSTRAINT table_columns_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: table_columns table_columns_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_columns
    ADD CONSTRAINT table_columns_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: table_schema table_schema_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_schema
    ADD CONSTRAINT table_schema_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: table_schema table_schema_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_schema
    ADD CONSTRAINT table_schema_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: table_schema table_schema_database_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_schema
    ADD CONSTRAINT table_schema_database_id_fkey FOREIGN KEY (database_id) REFERENCES public.dbs(id) ON DELETE CASCADE;


--
-- Name: table_schema table_schema_tab_state_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.table_schema
    ADD CONSTRAINT table_schema_tab_state_id_fkey FOREIGN KEY (tab_state_id) REFERENCES public.tab_state(id) ON DELETE CASCADE;


--
-- Name: tables tables_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tables
    ADD CONSTRAINT tables_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: tables tables_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tables
    ADD CONSTRAINT tables_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: tables tables_database_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tables
    ADD CONSTRAINT tables_database_id_fkey FOREIGN KEY (database_id) REFERENCES public.dbs(id);


--
-- Name: tag tag_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tag
    ADD CONSTRAINT tag_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: tag tag_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tag
    ADD CONSTRAINT tag_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: tagged_object tagged_object_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tagged_object
    ADD CONSTRAINT tagged_object_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: tagged_object tagged_object_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tagged_object
    ADD CONSTRAINT tagged_object_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: tagged_object tagged_object_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.tagged_object
    ADD CONSTRAINT tagged_object_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.tag(id);


--
-- Name: user_attribute user_attribute_changed_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.user_attribute
    ADD CONSTRAINT user_attribute_changed_by_fk_fkey FOREIGN KEY (changed_by_fk) REFERENCES public.ab_user(id);


--
-- Name: user_attribute user_attribute_created_by_fk_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.user_attribute
    ADD CONSTRAINT user_attribute_created_by_fk_fkey FOREIGN KEY (created_by_fk) REFERENCES public.ab_user(id);


--
-- Name: user_attribute user_attribute_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.user_attribute
    ADD CONSTRAINT user_attribute_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.ab_user(id);


--
-- Name: user_attribute user_attribute_welcome_dashboard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.user_attribute
    ADD CONSTRAINT user_attribute_welcome_dashboard_id_fkey FOREIGN KEY (welcome_dashboard_id) REFERENCES public.dashboards(id);


--
-- Name: user_favorite_tag user_favorite_tag_tag_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.user_favorite_tag
    ADD CONSTRAINT user_favorite_tag_tag_id_fkey FOREIGN KEY (tag_id) REFERENCES public.tag(id);


--
-- Name: user_favorite_tag user_favorite_tag_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.user_favorite_tag
    ADD CONSTRAINT user_favorite_tag_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.ab_user(id);


--
-- Name: jobs_partitioned; Type: ROW SECURITY; Schema: public; Owner: jobuser
--

ALTER TABLE public.jobs_partitioned ENABLE ROW LEVEL SECURITY;

--
-- Name: jobs_partitioned jobs_partitioned_all_access; Type: POLICY; Schema: public; Owner: jobuser
--

CREATE POLICY jobs_partitioned_all_access ON public.jobs_partitioned TO jobsdb_admin USING (true);


--
-- Name: jobs_partitioned jobs_partitioned_read_access; Type: POLICY; Schema: public; Owner: jobuser
--

CREATE POLICY jobs_partitioned_read_access ON public.jobs_partitioned FOR SELECT TO jobsdb_reader USING (true);


--
-- Name: jobs_partitioned jobs_partitioned_update_access; Type: POLICY; Schema: public; Owner: jobuser
--

CREATE POLICY jobs_partitioned_update_access ON public.jobs_partitioned FOR UPDATE TO jobsdb_writer USING (true) WITH CHECK (true);


--
-- Name: jobs_partitioned jobs_partitioned_write_access; Type: POLICY; Schema: public; Owner: jobuser
--

CREATE POLICY jobs_partitioned_write_access ON public.jobs_partitioned FOR INSERT TO jobsdb_writer WITH CHECK (true);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO jobsdb_reader;
GRANT USAGE ON SCHEMA public TO jobsdb_analyst;
GRANT USAGE ON SCHEMA public TO jobsdb_writer;
GRANT ALL ON SCHEMA public TO jobsdb_admin;


--
-- Name: FUNCTION create_future_job_partitions(years_ahead integer); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.create_future_job_partitions(years_ahead integer) TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.create_future_job_partitions(years_ahead integer) TO jobsdb_admin;


--
-- Name: FUNCTION create_job_partitions(p_start_year integer, p_end_year integer); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.create_job_partitions(p_start_year integer, p_end_year integer) TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.create_job_partitions(p_start_year integer, p_end_year integer) TO jobsdb_admin;


--
-- Name: FUNCTION create_new_partition_trigger(); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.create_new_partition_trigger() TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.create_new_partition_trigger() TO jobsdb_admin;


--
-- Name: FUNCTION get_jobs(p_tag_ids integer[], p_category_ids integer[], p_location_ids integer[], p_company_id text, p_min_salary double precision, p_max_salary double precision, p_from_date timestamp without time zone, p_to_date timestamp without time zone, p_limit integer, p_offset integer); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.get_jobs(p_tag_ids integer[], p_category_ids integer[], p_location_ids integer[], p_company_id text, p_min_salary double precision, p_max_salary double precision, p_from_date timestamp without time zone, p_to_date timestamp without time zone, p_limit integer, p_offset integer) TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.get_jobs(p_tag_ids integer[], p_category_ids integer[], p_location_ids integer[], p_company_id text, p_min_salary double precision, p_max_salary double precision, p_from_date timestamp without time zone, p_to_date timestamp without time zone, p_limit integer, p_offset integer) TO jobsdb_admin;


--
-- Name: FUNCTION health_check(); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.health_check() TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.health_check() TO jobsdb_admin;


--
-- Name: FUNCTION insert_job(p_id text, p_title text, p_url text, p_locations jsonb, p_work_types jsonb, p_salary jsonb, p_gender text, p_tags jsonb, p_item_index integer, p_job_post_categories jsonb, p_company_fa_name text, p_province_match_city text, p_normalize_salary_min double precision, p_normalize_salary_max double precision, p_payment_method text, p_district text, p_company_title_fa text, p_job_board_id text, p_job_board_title_en text, p_activation_time timestamp without time zone, p_company_id text, p_company_name_fa text, p_company_name_en text, p_company_about text, p_company_url text, p_location_ids text, p_tag_number text, p_raw_data jsonb, p_batch_id text, p_batch_date timestamp without time zone); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.insert_job(p_id text, p_title text, p_url text, p_locations jsonb, p_work_types jsonb, p_salary jsonb, p_gender text, p_tags jsonb, p_item_index integer, p_job_post_categories jsonb, p_company_fa_name text, p_province_match_city text, p_normalize_salary_min double precision, p_normalize_salary_max double precision, p_payment_method text, p_district text, p_company_title_fa text, p_job_board_id text, p_job_board_title_en text, p_activation_time timestamp without time zone, p_company_id text, p_company_name_fa text, p_company_name_en text, p_company_about text, p_company_url text, p_location_ids text, p_tag_number text, p_raw_data jsonb, p_batch_id text, p_batch_date timestamp without time zone) TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.insert_job(p_id text, p_title text, p_url text, p_locations jsonb, p_work_types jsonb, p_salary jsonb, p_gender text, p_tags jsonb, p_item_index integer, p_job_post_categories jsonb, p_company_fa_name text, p_province_match_city text, p_normalize_salary_min double precision, p_normalize_salary_max double precision, p_payment_method text, p_district text, p_company_title_fa text, p_job_board_id text, p_job_board_title_en text, p_activation_time timestamp without time zone, p_company_id text, p_company_name_fa text, p_company_name_en text, p_company_about text, p_company_url text, p_location_ids text, p_tag_number text, p_raw_data jsonb, p_batch_id text, p_batch_date timestamp without time zone) TO jobsdb_admin;


--
-- Name: FUNCTION insert_or_update_job(p_title text, p_description text, p_company_name text, p_company_url text, p_location_name text, p_is_remote boolean, p_work_type_name text, p_salary_min numeric, p_salary_max numeric, p_currency text, p_url text, p_source text, p_batch_date date, p_tags text[], p_categories text[]); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.insert_or_update_job(p_title text, p_description text, p_company_name text, p_company_url text, p_location_name text, p_is_remote boolean, p_work_type_name text, p_salary_min numeric, p_salary_max numeric, p_currency text, p_url text, p_source text, p_batch_date date, p_tags text[], p_categories text[]) TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.insert_or_update_job(p_title text, p_description text, p_company_name text, p_company_url text, p_location_name text, p_is_remote boolean, p_work_type_name text, p_salary_min numeric, p_salary_max numeric, p_currency text, p_url text, p_source text, p_batch_date date, p_tags text[], p_categories text[]) TO jobsdb_admin;


--
-- Name: FUNCTION jobs_view_delete_trigger(); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.jobs_view_delete_trigger() TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.jobs_view_delete_trigger() TO jobsdb_admin;


--
-- Name: FUNCTION jobs_view_insert_trigger(); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.jobs_view_insert_trigger() TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.jobs_view_insert_trigger() TO jobsdb_admin;


--
-- Name: FUNCTION jobs_view_update_trigger(); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.jobs_view_update_trigger() TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.jobs_view_update_trigger() TO jobsdb_admin;


--
-- Name: FUNCTION maintain_partitions(); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.maintain_partitions() TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.maintain_partitions() TO jobsdb_admin;


--
-- Name: FUNCTION migrate_to_partitioned_jobs(); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.migrate_to_partitioned_jobs() TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.migrate_to_partitioned_jobs() TO jobsdb_admin;


--
-- Name: FUNCTION refresh_all_job_materialized_views(); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.refresh_all_job_materialized_views() TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.refresh_all_job_materialized_views() TO jobsdb_admin;


--
-- Name: FUNCTION refresh_all_materialized_views(); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.refresh_all_materialized_views() TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.refresh_all_materialized_views() TO jobsdb_admin;


--
-- Name: FUNCTION update_job_batch(p_id text, p_scraper_name text, p_scrape_date timestamp without time zone, p_status text, p_job_count integer, p_error_message text); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.update_job_batch(p_id text, p_scraper_name text, p_scrape_date timestamp without time zone, p_status text, p_job_count integer, p_error_message text) TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.update_job_batch(p_id text, p_scraper_name text, p_scrape_date timestamp without time zone, p_status text, p_job_count integer, p_error_message text) TO jobsdb_admin;


--
-- Name: FUNCTION update_updated_at_column(); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.update_updated_at_column() TO jobsdb_analyst;
GRANT ALL ON FUNCTION public.update_updated_at_column() TO jobsdb_admin;


--
-- Name: TABLE ab_permission; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.ab_permission TO jobsdb_reader;
GRANT SELECT ON TABLE public.ab_permission TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ab_permission TO jobsdb_writer;
GRANT ALL ON TABLE public.ab_permission TO jobsdb_admin;


--
-- Name: SEQUENCE ab_permission_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.ab_permission_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.ab_permission_id_seq TO jobsdb_admin;


--
-- Name: TABLE ab_permission_view; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.ab_permission_view TO jobsdb_reader;
GRANT SELECT ON TABLE public.ab_permission_view TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ab_permission_view TO jobsdb_writer;
GRANT ALL ON TABLE public.ab_permission_view TO jobsdb_admin;


--
-- Name: SEQUENCE ab_permission_view_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.ab_permission_view_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.ab_permission_view_id_seq TO jobsdb_admin;


--
-- Name: TABLE ab_permission_view_role; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.ab_permission_view_role TO jobsdb_reader;
GRANT SELECT ON TABLE public.ab_permission_view_role TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ab_permission_view_role TO jobsdb_writer;
GRANT ALL ON TABLE public.ab_permission_view_role TO jobsdb_admin;


--
-- Name: SEQUENCE ab_permission_view_role_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.ab_permission_view_role_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.ab_permission_view_role_id_seq TO jobsdb_admin;


--
-- Name: TABLE ab_register_user; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.ab_register_user TO jobsdb_reader;
GRANT SELECT ON TABLE public.ab_register_user TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ab_register_user TO jobsdb_writer;
GRANT ALL ON TABLE public.ab_register_user TO jobsdb_admin;


--
-- Name: SEQUENCE ab_register_user_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.ab_register_user_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.ab_register_user_id_seq TO jobsdb_admin;


--
-- Name: TABLE ab_role; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.ab_role TO jobsdb_reader;
GRANT SELECT ON TABLE public.ab_role TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ab_role TO jobsdb_writer;
GRANT ALL ON TABLE public.ab_role TO jobsdb_admin;


--
-- Name: SEQUENCE ab_role_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.ab_role_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.ab_role_id_seq TO jobsdb_admin;


--
-- Name: TABLE ab_user; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.ab_user TO jobsdb_reader;
GRANT SELECT ON TABLE public.ab_user TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ab_user TO jobsdb_writer;
GRANT ALL ON TABLE public.ab_user TO jobsdb_admin;


--
-- Name: SEQUENCE ab_user_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.ab_user_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.ab_user_id_seq TO jobsdb_admin;


--
-- Name: TABLE ab_user_role; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.ab_user_role TO jobsdb_reader;
GRANT SELECT ON TABLE public.ab_user_role TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ab_user_role TO jobsdb_writer;
GRANT ALL ON TABLE public.ab_user_role TO jobsdb_admin;


--
-- Name: SEQUENCE ab_user_role_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.ab_user_role_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.ab_user_role_id_seq TO jobsdb_admin;


--
-- Name: TABLE ab_view_menu; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.ab_view_menu TO jobsdb_reader;
GRANT SELECT ON TABLE public.ab_view_menu TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ab_view_menu TO jobsdb_writer;
GRANT ALL ON TABLE public.ab_view_menu TO jobsdb_admin;


--
-- Name: SEQUENCE ab_view_menu_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.ab_view_menu_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.ab_view_menu_id_seq TO jobsdb_admin;


--
-- Name: TABLE alembic_version; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.alembic_version TO jobsdb_reader;
GRANT SELECT ON TABLE public.alembic_version TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.alembic_version TO jobsdb_writer;
GRANT ALL ON TABLE public.alembic_version TO jobsdb_admin;


--
-- Name: TABLE annotation; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.annotation TO jobsdb_reader;
GRANT SELECT ON TABLE public.annotation TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.annotation TO jobsdb_writer;
GRANT ALL ON TABLE public.annotation TO jobsdb_admin;


--
-- Name: SEQUENCE annotation_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.annotation_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.annotation_id_seq TO jobsdb_admin;


--
-- Name: TABLE annotation_layer; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.annotation_layer TO jobsdb_reader;
GRANT SELECT ON TABLE public.annotation_layer TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.annotation_layer TO jobsdb_writer;
GRANT ALL ON TABLE public.annotation_layer TO jobsdb_admin;


--
-- Name: SEQUENCE annotation_layer_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.annotation_layer_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.annotation_layer_id_seq TO jobsdb_admin;


--
-- Name: TABLE cache_keys; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.cache_keys TO jobsdb_reader;
GRANT SELECT ON TABLE public.cache_keys TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.cache_keys TO jobsdb_writer;
GRANT ALL ON TABLE public.cache_keys TO jobsdb_admin;


--
-- Name: SEQUENCE cache_keys_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.cache_keys_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.cache_keys_id_seq TO jobsdb_admin;


--
-- Name: TABLE companies; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.companies TO jobsdb_reader;
GRANT SELECT ON TABLE public.companies TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.companies TO jobsdb_writer;
GRANT ALL ON TABLE public.companies TO jobsdb_admin;


--
-- Name: SEQUENCE companies_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.companies_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.companies_id_seq TO jobsdb_admin;


--
-- Name: TABLE css_templates; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.css_templates TO jobsdb_reader;
GRANT SELECT ON TABLE public.css_templates TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.css_templates TO jobsdb_writer;
GRANT ALL ON TABLE public.css_templates TO jobsdb_admin;


--
-- Name: SEQUENCE css_templates_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.css_templates_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.css_templates_id_seq TO jobsdb_admin;


--
-- Name: TABLE dashboard_roles; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.dashboard_roles TO jobsdb_reader;
GRANT SELECT ON TABLE public.dashboard_roles TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.dashboard_roles TO jobsdb_writer;
GRANT ALL ON TABLE public.dashboard_roles TO jobsdb_admin;


--
-- Name: SEQUENCE dashboard_roles_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.dashboard_roles_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.dashboard_roles_id_seq TO jobsdb_admin;


--
-- Name: TABLE dashboard_slices; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.dashboard_slices TO jobsdb_reader;
GRANT SELECT ON TABLE public.dashboard_slices TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.dashboard_slices TO jobsdb_writer;
GRANT ALL ON TABLE public.dashboard_slices TO jobsdb_admin;


--
-- Name: SEQUENCE dashboard_slices_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.dashboard_slices_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.dashboard_slices_id_seq TO jobsdb_admin;


--
-- Name: TABLE dashboard_user; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.dashboard_user TO jobsdb_reader;
GRANT SELECT ON TABLE public.dashboard_user TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.dashboard_user TO jobsdb_writer;
GRANT ALL ON TABLE public.dashboard_user TO jobsdb_admin;


--
-- Name: SEQUENCE dashboard_user_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.dashboard_user_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.dashboard_user_id_seq TO jobsdb_admin;


--
-- Name: TABLE dashboards; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.dashboards TO jobsdb_reader;
GRANT SELECT ON TABLE public.dashboards TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.dashboards TO jobsdb_writer;
GRANT ALL ON TABLE public.dashboards TO jobsdb_admin;


--
-- Name: SEQUENCE dashboards_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.dashboards_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.dashboards_id_seq TO jobsdb_admin;


--
-- Name: TABLE database_user_oauth2_tokens; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.database_user_oauth2_tokens TO jobsdb_reader;
GRANT SELECT ON TABLE public.database_user_oauth2_tokens TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.database_user_oauth2_tokens TO jobsdb_writer;
GRANT ALL ON TABLE public.database_user_oauth2_tokens TO jobsdb_admin;


--
-- Name: SEQUENCE database_user_oauth2_tokens_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.database_user_oauth2_tokens_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.database_user_oauth2_tokens_id_seq TO jobsdb_admin;


--
-- Name: TABLE dbs; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.dbs TO jobsdb_reader;
GRANT SELECT ON TABLE public.dbs TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.dbs TO jobsdb_writer;
GRANT ALL ON TABLE public.dbs TO jobsdb_admin;


--
-- Name: SEQUENCE dbs_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.dbs_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.dbs_id_seq TO jobsdb_admin;


--
-- Name: TABLE dynamic_plugin; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.dynamic_plugin TO jobsdb_reader;
GRANT SELECT ON TABLE public.dynamic_plugin TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.dynamic_plugin TO jobsdb_writer;
GRANT ALL ON TABLE public.dynamic_plugin TO jobsdb_admin;


--
-- Name: SEQUENCE dynamic_plugin_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.dynamic_plugin_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.dynamic_plugin_id_seq TO jobsdb_admin;


--
-- Name: TABLE embedded_dashboards; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.embedded_dashboards TO jobsdb_reader;
GRANT SELECT ON TABLE public.embedded_dashboards TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.embedded_dashboards TO jobsdb_writer;
GRANT ALL ON TABLE public.embedded_dashboards TO jobsdb_admin;


--
-- Name: TABLE favstar; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.favstar TO jobsdb_reader;
GRANT SELECT ON TABLE public.favstar TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.favstar TO jobsdb_writer;
GRANT ALL ON TABLE public.favstar TO jobsdb_admin;


--
-- Name: SEQUENCE favstar_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.favstar_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.favstar_id_seq TO jobsdb_admin;


--
-- Name: TABLE job_batches_new; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_new TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_new TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_new TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_new TO jobsdb_admin;


--
-- Name: SEQUENCE job_batches_new_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.job_batches_new_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.job_batches_new_id_seq TO jobsdb_admin;


--
-- Name: TABLE job_batches_partitioned; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_partitioned TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_partitioned TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_partitioned TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_partitioned TO jobsdb_admin;


--
-- Name: SEQUENCE job_batches_partitioned_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.job_batches_partitioned_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.job_batches_partitioned_id_seq TO jobsdb_admin;


--
-- Name: TABLE job_batches_p2025_01; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_p2025_01 TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_p2025_01 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_p2025_01 TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_p2025_01 TO jobsdb_admin;


--
-- Name: TABLE job_batches_p2025_02; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_p2025_02 TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_p2025_02 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_p2025_02 TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_p2025_02 TO jobsdb_admin;


--
-- Name: TABLE job_batches_p2025_03; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_p2025_03 TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_p2025_03 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_p2025_03 TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_p2025_03 TO jobsdb_admin;


--
-- Name: TABLE job_batches_p2025_04; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_p2025_04 TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_p2025_04 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_p2025_04 TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_p2025_04 TO jobsdb_admin;


--
-- Name: TABLE job_batches_p2025_05; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_p2025_05 TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_p2025_05 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_p2025_05 TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_p2025_05 TO jobsdb_admin;


--
-- Name: TABLE job_batches_p2025_06; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_p2025_06 TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_p2025_06 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_p2025_06 TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_p2025_06 TO jobsdb_admin;


--
-- Name: TABLE job_batches_p2025_07; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_p2025_07 TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_p2025_07 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_p2025_07 TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_p2025_07 TO jobsdb_admin;


--
-- Name: TABLE job_batches_p2025_08; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_p2025_08 TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_p2025_08 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_p2025_08 TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_p2025_08 TO jobsdb_admin;


--
-- Name: TABLE job_batches_p2025_09; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_p2025_09 TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_p2025_09 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_p2025_09 TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_p2025_09 TO jobsdb_admin;


--
-- Name: TABLE job_batches_p2025_10; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_p2025_10 TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_p2025_10 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_p2025_10 TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_p2025_10 TO jobsdb_admin;


--
-- Name: TABLE job_batches_p2025_11; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_p2025_11 TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_p2025_11 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_p2025_11 TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_p2025_11 TO jobsdb_admin;


--
-- Name: TABLE job_batches_p2025_12; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_p2025_12 TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_batches_p2025_12 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_p2025_12 TO jobsdb_writer;
GRANT ALL ON TABLE public.job_batches_p2025_12 TO jobsdb_admin;


--
-- Name: TABLE job_categories; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_categories TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_categories TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_categories TO jobsdb_writer;
GRANT ALL ON TABLE public.job_categories TO jobsdb_admin;


--
-- Name: SEQUENCE job_categories_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.job_categories_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.job_categories_id_seq TO jobsdb_admin;


--
-- Name: TABLE job_tags; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_tags TO jobsdb_reader;
GRANT SELECT ON TABLE public.job_tags TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_tags TO jobsdb_writer;
GRANT ALL ON TABLE public.job_tags TO jobsdb_admin;


--
-- Name: SEQUENCE job_tags_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.job_tags_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.job_tags_id_seq TO jobsdb_admin;


--
-- Name: TABLE jobs_partitioned; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_partitioned TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_partitioned TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_partitioned TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_partitioned TO jobsdb_admin;


--
-- Name: SEQUENCE jobs_partitioned_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.jobs_partitioned_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.jobs_partitioned_id_seq TO jobsdb_admin;


--
-- Name: TABLE jobs_p2025_01; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2025_01 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2025_01 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2025_01 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2025_01 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2025_02; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2025_02 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2025_02 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2025_02 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2025_02 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2025_03; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2025_03 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2025_03 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2025_03 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2025_03 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2025_04; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2025_04 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2025_04 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2025_04 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2025_04 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2025_05; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2025_05 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2025_05 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2025_05 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2025_05 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2025_06; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2025_06 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2025_06 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2025_06 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2025_06 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2025_07; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2025_07 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2025_07 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2025_07 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2025_07 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2025_08; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2025_08 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2025_08 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2025_08 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2025_08 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2025_09; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2025_09 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2025_09 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2025_09 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2025_09 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2025_10; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2025_10 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2025_10 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2025_10 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2025_10 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2025_11; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2025_11 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2025_11 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2025_11 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2025_11 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2025_12; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2025_12 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2025_12 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2025_12 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2025_12 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2026_01; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2026_01 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2026_01 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2026_01 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2026_01 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2026_02; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2026_02 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2026_02 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2026_02 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2026_02 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2026_03; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2026_03 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2026_03 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2026_03 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2026_03 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2026_04; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2026_04 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2026_04 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2026_04 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2026_04 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2026_05; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2026_05 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2026_05 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2026_05 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2026_05 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2026_06; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2026_06 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2026_06 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2026_06 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2026_06 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2026_07; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2026_07 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2026_07 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2026_07 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2026_07 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2026_08; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2026_08 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2026_08 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2026_08 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2026_08 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2026_09; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2026_09 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2026_09 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2026_09 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2026_09 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2026_10; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2026_10 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2026_10 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2026_10 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2026_10 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2026_11; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2026_11 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2026_11 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2026_11 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2026_11 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2026_12; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2026_12 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2026_12 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2026_12 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2026_12 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2027_01; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2027_01 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2027_01 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2027_01 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2027_01 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2027_02; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2027_02 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2027_02 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2027_02 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2027_02 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2027_03; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2027_03 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2027_03 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2027_03 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2027_03 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2027_04; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2027_04 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2027_04 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2027_04 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2027_04 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2027_05; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2027_05 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2027_05 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2027_05 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2027_05 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2027_06; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2027_06 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2027_06 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2027_06 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2027_06 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2027_07; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2027_07 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2027_07 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2027_07 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2027_07 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2027_08; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2027_08 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2027_08 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2027_08 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2027_08 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2027_09; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2027_09 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2027_09 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2027_09 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2027_09 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2027_10; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2027_10 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2027_10 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2027_10 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2027_10 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2027_11; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2027_11 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2027_11 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2027_11 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2027_11 TO jobsdb_admin;


--
-- Name: TABLE jobs_p2027_12; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_p2027_12 TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_p2027_12 TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_p2027_12 TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_p2027_12 TO jobsdb_admin;


--
-- Name: TABLE jobs_view; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.jobs_view TO jobsdb_reader;
GRANT SELECT ON TABLE public.jobs_view TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.jobs_view TO jobsdb_writer;
GRANT ALL ON TABLE public.jobs_view TO jobsdb_admin;


--
-- Name: TABLE key_value; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.key_value TO jobsdb_reader;
GRANT SELECT ON TABLE public.key_value TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.key_value TO jobsdb_writer;
GRANT ALL ON TABLE public.key_value TO jobsdb_admin;


--
-- Name: SEQUENCE key_value_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.key_value_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.key_value_id_seq TO jobsdb_admin;


--
-- Name: TABLE keyvalue; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.keyvalue TO jobsdb_reader;
GRANT SELECT ON TABLE public.keyvalue TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.keyvalue TO jobsdb_writer;
GRANT ALL ON TABLE public.keyvalue TO jobsdb_admin;


--
-- Name: SEQUENCE keyvalue_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.keyvalue_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.keyvalue_id_seq TO jobsdb_admin;


--
-- Name: TABLE locations; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.locations TO jobsdb_reader;
GRANT SELECT ON TABLE public.locations TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.locations TO jobsdb_writer;
GRANT ALL ON TABLE public.locations TO jobsdb_admin;


--
-- Name: SEQUENCE locations_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.locations_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.locations_id_seq TO jobsdb_admin;


--
-- Name: TABLE logs; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.logs TO jobsdb_reader;
GRANT SELECT ON TABLE public.logs TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.logs TO jobsdb_writer;
GRANT ALL ON TABLE public.logs TO jobsdb_admin;


--
-- Name: SEQUENCE logs_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.logs_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.logs_id_seq TO jobsdb_admin;


--
-- Name: TABLE query; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.query TO jobsdb_reader;
GRANT SELECT ON TABLE public.query TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.query TO jobsdb_writer;
GRANT ALL ON TABLE public.query TO jobsdb_admin;


--
-- Name: SEQUENCE query_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.query_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.query_id_seq TO jobsdb_admin;


--
-- Name: TABLE report_execution_log; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.report_execution_log TO jobsdb_reader;
GRANT SELECT ON TABLE public.report_execution_log TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.report_execution_log TO jobsdb_writer;
GRANT ALL ON TABLE public.report_execution_log TO jobsdb_admin;


--
-- Name: SEQUENCE report_execution_log_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.report_execution_log_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.report_execution_log_id_seq TO jobsdb_admin;


--
-- Name: TABLE report_recipient; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.report_recipient TO jobsdb_reader;
GRANT SELECT ON TABLE public.report_recipient TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.report_recipient TO jobsdb_writer;
GRANT ALL ON TABLE public.report_recipient TO jobsdb_admin;


--
-- Name: SEQUENCE report_recipient_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.report_recipient_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.report_recipient_id_seq TO jobsdb_admin;


--
-- Name: TABLE report_schedule; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.report_schedule TO jobsdb_reader;
GRANT SELECT ON TABLE public.report_schedule TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.report_schedule TO jobsdb_writer;
GRANT ALL ON TABLE public.report_schedule TO jobsdb_admin;


--
-- Name: SEQUENCE report_schedule_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.report_schedule_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.report_schedule_id_seq TO jobsdb_admin;


--
-- Name: TABLE report_schedule_user; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.report_schedule_user TO jobsdb_reader;
GRANT SELECT ON TABLE public.report_schedule_user TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.report_schedule_user TO jobsdb_writer;
GRANT ALL ON TABLE public.report_schedule_user TO jobsdb_admin;


--
-- Name: SEQUENCE report_schedule_user_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.report_schedule_user_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.report_schedule_user_id_seq TO jobsdb_admin;


--
-- Name: TABLE rls_filter_roles; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.rls_filter_roles TO jobsdb_reader;
GRANT SELECT ON TABLE public.rls_filter_roles TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rls_filter_roles TO jobsdb_writer;
GRANT ALL ON TABLE public.rls_filter_roles TO jobsdb_admin;


--
-- Name: SEQUENCE rls_filter_roles_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.rls_filter_roles_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.rls_filter_roles_id_seq TO jobsdb_admin;


--
-- Name: TABLE rls_filter_tables; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.rls_filter_tables TO jobsdb_reader;
GRANT SELECT ON TABLE public.rls_filter_tables TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.rls_filter_tables TO jobsdb_writer;
GRANT ALL ON TABLE public.rls_filter_tables TO jobsdb_admin;


--
-- Name: SEQUENCE rls_filter_tables_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.rls_filter_tables_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.rls_filter_tables_id_seq TO jobsdb_admin;


--
-- Name: TABLE row_level_security_filters; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.row_level_security_filters TO jobsdb_reader;
GRANT SELECT ON TABLE public.row_level_security_filters TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.row_level_security_filters TO jobsdb_writer;
GRANT ALL ON TABLE public.row_level_security_filters TO jobsdb_admin;


--
-- Name: SEQUENCE row_level_security_filters_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.row_level_security_filters_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.row_level_security_filters_id_seq TO jobsdb_admin;


--
-- Name: TABLE saved_query; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.saved_query TO jobsdb_reader;
GRANT SELECT ON TABLE public.saved_query TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.saved_query TO jobsdb_writer;
GRANT ALL ON TABLE public.saved_query TO jobsdb_admin;


--
-- Name: SEQUENCE saved_query_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.saved_query_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.saved_query_id_seq TO jobsdb_admin;


--
-- Name: TABLE schema_version; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.schema_version TO jobsdb_reader;
GRANT SELECT ON TABLE public.schema_version TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.schema_version TO jobsdb_writer;
GRANT ALL ON TABLE public.schema_version TO jobsdb_admin;


--
-- Name: SEQUENCE schema_version_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.schema_version_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.schema_version_id_seq TO jobsdb_admin;


--
-- Name: TABLE slice_user; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.slice_user TO jobsdb_reader;
GRANT SELECT ON TABLE public.slice_user TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.slice_user TO jobsdb_writer;
GRANT ALL ON TABLE public.slice_user TO jobsdb_admin;


--
-- Name: SEQUENCE slice_user_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.slice_user_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.slice_user_id_seq TO jobsdb_admin;


--
-- Name: TABLE slices; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.slices TO jobsdb_reader;
GRANT SELECT ON TABLE public.slices TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.slices TO jobsdb_writer;
GRANT ALL ON TABLE public.slices TO jobsdb_admin;


--
-- Name: SEQUENCE slices_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.slices_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.slices_id_seq TO jobsdb_admin;


--
-- Name: TABLE sql_metrics; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.sql_metrics TO jobsdb_reader;
GRANT SELECT ON TABLE public.sql_metrics TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.sql_metrics TO jobsdb_writer;
GRANT ALL ON TABLE public.sql_metrics TO jobsdb_admin;


--
-- Name: SEQUENCE sql_metrics_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.sql_metrics_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.sql_metrics_id_seq TO jobsdb_admin;


--
-- Name: TABLE sqlatable_user; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.sqlatable_user TO jobsdb_reader;
GRANT SELECT ON TABLE public.sqlatable_user TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.sqlatable_user TO jobsdb_writer;
GRANT ALL ON TABLE public.sqlatable_user TO jobsdb_admin;


--
-- Name: SEQUENCE sqlatable_user_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.sqlatable_user_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.sqlatable_user_id_seq TO jobsdb_admin;


--
-- Name: TABLE ssh_tunnels; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.ssh_tunnels TO jobsdb_reader;
GRANT SELECT ON TABLE public.ssh_tunnels TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.ssh_tunnels TO jobsdb_writer;
GRANT ALL ON TABLE public.ssh_tunnels TO jobsdb_admin;


--
-- Name: SEQUENCE ssh_tunnels_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.ssh_tunnels_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.ssh_tunnels_id_seq TO jobsdb_admin;


--
-- Name: TABLE tab_state; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.tab_state TO jobsdb_reader;
GRANT SELECT ON TABLE public.tab_state TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.tab_state TO jobsdb_writer;
GRANT ALL ON TABLE public.tab_state TO jobsdb_admin;


--
-- Name: SEQUENCE tab_state_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.tab_state_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.tab_state_id_seq TO jobsdb_admin;


--
-- Name: TABLE table_columns; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.table_columns TO jobsdb_reader;
GRANT SELECT ON TABLE public.table_columns TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.table_columns TO jobsdb_writer;
GRANT ALL ON TABLE public.table_columns TO jobsdb_admin;


--
-- Name: SEQUENCE table_columns_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.table_columns_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.table_columns_id_seq TO jobsdb_admin;


--
-- Name: TABLE table_schema; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.table_schema TO jobsdb_reader;
GRANT SELECT ON TABLE public.table_schema TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.table_schema TO jobsdb_writer;
GRANT ALL ON TABLE public.table_schema TO jobsdb_admin;


--
-- Name: SEQUENCE table_schema_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.table_schema_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.table_schema_id_seq TO jobsdb_admin;


--
-- Name: TABLE tables; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.tables TO jobsdb_reader;
GRANT SELECT ON TABLE public.tables TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.tables TO jobsdb_writer;
GRANT ALL ON TABLE public.tables TO jobsdb_admin;


--
-- Name: SEQUENCE tables_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.tables_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.tables_id_seq TO jobsdb_admin;


--
-- Name: TABLE tag; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.tag TO jobsdb_reader;
GRANT SELECT ON TABLE public.tag TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.tag TO jobsdb_writer;
GRANT ALL ON TABLE public.tag TO jobsdb_admin;


--
-- Name: SEQUENCE tag_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.tag_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.tag_id_seq TO jobsdb_admin;


--
-- Name: TABLE tagged_object; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.tagged_object TO jobsdb_reader;
GRANT SELECT ON TABLE public.tagged_object TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.tagged_object TO jobsdb_writer;
GRANT ALL ON TABLE public.tagged_object TO jobsdb_admin;


--
-- Name: SEQUENCE tagged_object_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.tagged_object_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.tagged_object_id_seq TO jobsdb_admin;


--
-- Name: TABLE user_attribute; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.user_attribute TO jobsdb_reader;
GRANT SELECT ON TABLE public.user_attribute TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_attribute TO jobsdb_writer;
GRANT ALL ON TABLE public.user_attribute TO jobsdb_admin;


--
-- Name: SEQUENCE user_attribute_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.user_attribute_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.user_attribute_id_seq TO jobsdb_admin;


--
-- Name: TABLE user_favorite_tag; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.user_favorite_tag TO jobsdb_reader;
GRANT SELECT ON TABLE public.user_favorite_tag TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.user_favorite_tag TO jobsdb_writer;
GRANT ALL ON TABLE public.user_favorite_tag TO jobsdb_admin;


--
-- Name: TABLE work_types; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.work_types TO jobsdb_reader;
GRANT SELECT ON TABLE public.work_types TO jobsdb_analyst;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.work_types TO jobsdb_writer;
GRANT ALL ON TABLE public.work_types TO jobsdb_admin;


--
-- Name: SEQUENCE work_types_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT USAGE ON SEQUENCE public.work_types_id_seq TO jobsdb_writer;
GRANT ALL ON SEQUENCE public.work_types_id_seq TO jobsdb_admin;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: jobuser
--

ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES  TO jobuser;
ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT USAGE ON SEQUENCES  TO jobsdb_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT ALL ON SEQUENCES  TO jobsdb_admin;


--
-- Name: DEFAULT PRIVILEGES FOR FUNCTIONS; Type: DEFAULT ACL; Schema: public; Owner: jobuser
--

ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT ALL ON FUNCTIONS  TO jobsdb_analyst;
ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT ALL ON FUNCTIONS  TO jobsdb_admin;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: jobuser
--

ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES  TO jobuser;
ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT SELECT ON TABLES  TO jobsdb_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT SELECT ON TABLES  TO jobsdb_analyst;
ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES  TO jobsdb_writer;
ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT ALL ON TABLES  TO jobsdb_admin;


--
-- PostgreSQL database dump complete
--

