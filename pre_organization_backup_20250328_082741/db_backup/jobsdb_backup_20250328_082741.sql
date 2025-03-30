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
-- Name: companies id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.companies ALTER COLUMN id SET DEFAULT nextval('public.companies_id_seq'::regclass);


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
-- Name: locations id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.locations ALTER COLUMN id SET DEFAULT nextval('public.locations_id_seq'::regclass);


--
-- Name: schema_version id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.schema_version ALTER COLUMN id SET DEFAULT nextval('public.schema_version_id_seq'::regclass);


--
-- Name: work_types id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.work_types ALTER COLUMN id SET DEFAULT nextval('public.work_types_id_seq'::regclass);


--
-- Data for Name: companies; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.companies (id, name, url, logo_url, description, created_at, updated_at) FROM stdin;
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
-- Data for Name: locations; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.locations (id, name, country, city, is_remote, created_at) FROM stdin;
1	Remote	\N	\N	t	2025-03-27 18:34:08.10865
2	Tehran	\N	\N	f	2025-03-27 18:34:08.10865
3	Mashhad	\N	\N	f	2025-03-27 18:34:08.10865
4	Isfahan	\N	\N	f	2025-03-27 18:34:08.10865
5	Shiraz	\N	\N	f	2025-03-27 18:34:08.10865
\.


--
-- Data for Name: schema_version; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.schema_version (id, version, description, applied_at) FROM stdin;
1	2	Initial normalized schema migration	2025-03-27 18:34:09.219939
\.


--
-- Data for Name: work_types; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.work_types (id, name, description, created_at) FROM stdin;
1	Full-time	\N	2025-03-27 18:34:08.106275
2	Part-time	\N	2025-03-27 18:34:08.106275
3	Contract	\N	2025-03-27 18:34:08.106275
4	Freelance	\N	2025-03-27 18:34:08.106275
5	Internship	\N	2025-03-27 18:34:08.106275
\.


--
-- Name: companies_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.companies_id_seq', 1, false);


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
-- Name: locations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.locations_id_seq', 10, true);


--
-- Name: schema_version_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.schema_version_id_seq', 1, true);


--
-- Name: work_types_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.work_types_id_seq', 10, true);


--
-- Name: companies companies_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_pkey PRIMARY KEY (id);


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
-- Name: locations locations_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT locations_pkey PRIMARY KEY (id);


--
-- Name: schema_version schema_version_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.schema_version
    ADD CONSTRAINT schema_version_pkey PRIMARY KEY (id);


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
-- Name: idx_work_types_name; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_work_types_name ON public.work_types USING btree (name);


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
-- Name: jobs_partitioned jobs_partitioned_company_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE public.jobs_partitioned
    ADD CONSTRAINT jobs_partitioned_company_id_fkey FOREIGN KEY (company_id) REFERENCES public.companies(id);


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

