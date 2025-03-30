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
    id text NOT NULL,
    name_fa text,
    name_en text,
    title_fa text,
    about text,
    url text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.companies OWNER TO jobuser;

--
-- Name: job_batches_new; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_new (
    batch_id text NOT NULL,
    batch_date timestamp without time zone NOT NULL,
    job_count integer DEFAULT 0,
    source text,
    processing_time double precision,
    status text,
    error_message text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    completed_at timestamp without time zone
);


ALTER TABLE public.job_batches_new OWNER TO jobuser;

--
-- Name: job_batches_partitioned; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_batches_partitioned (
    id integer NOT NULL,
    site text NOT NULL,
    query jsonb,
    status text NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    total_jobs integer DEFAULT 0,
    new_jobs integer DEFAULT 0,
    updated_jobs integer DEFAULT 0
)
PARTITION BY RANGE (created_at);


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
-- Name: job_categories; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_categories (
    id integer NOT NULL,
    name_fa text NOT NULL,
    name_en text,
    parent_id integer,
    url_parameter text,
    seo_order integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE public.job_categories OWNER TO jobuser;

--
-- Name: job_tags; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.job_tags (
    id integer NOT NULL,
    name_fa text NOT NULL,
    name_en text,
    tag_type text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


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
-- Name: locations; Type: TABLE; Schema: public; Owner: jobuser
--

CREATE TABLE public.locations (
    id integer NOT NULL,
    name_fa text NOT NULL,
    name_en text,
    parent_id integer,
    location_type text,
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
    name_fa text NOT NULL,
    name_en text,
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
-- Name: job_batches_partitioned id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned ALTER COLUMN id SET DEFAULT nextval('public.job_batches_partitioned_id_seq'::regclass);


--
-- Name: job_tags id; Type: DEFAULT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_tags ALTER COLUMN id SET DEFAULT nextval('public.job_tags_id_seq'::regclass);


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

COPY public.companies (id, name_fa, name_en, title_fa, about, url, created_at, updated_at) FROM stdin;
\.


--
-- Data for Name: job_batches_new; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_batches_new (batch_id, batch_date, job_count, source, processing_time, status, error_message, created_at, completed_at) FROM stdin;
\.


--
-- Data for Name: job_categories; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_categories (id, name_fa, name_en, parent_id, url_parameter, seo_order, created_at) FROM stdin;
\.


--
-- Data for Name: job_tags; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.job_tags (id, name_fa, name_en, tag_type, created_at) FROM stdin;
\.


--
-- Data for Name: locations; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.locations (id, name_fa, name_en, parent_id, location_type, created_at) FROM stdin;
\.


--
-- Data for Name: schema_version; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.schema_version (id, version, description, applied_at) FROM stdin;
1	2	Initial normalized schema migration	2025-03-27 17:34:15.842245
\.


--
-- Data for Name: work_types; Type: TABLE DATA; Schema: public; Owner: jobuser
--

COPY public.work_types (id, name_fa, name_en, created_at) FROM stdin;
\.


--
-- Name: job_batches_partitioned_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.job_batches_partitioned_id_seq', 1, false);


--
-- Name: job_tags_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.job_tags_id_seq', 1, false);


--
-- Name: locations_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.locations_id_seq', 1, false);


--
-- Name: schema_version_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.schema_version_id_seq', 1, true);


--
-- Name: work_types_id_seq; Type: SEQUENCE SET; Schema: public; Owner: jobuser
--

SELECT pg_catalog.setval('public.work_types_id_seq', 1, false);


--
-- Name: companies companies_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.companies
    ADD CONSTRAINT companies_pkey PRIMARY KEY (id);


--
-- Name: job_batches_new job_batches_new_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_new
    ADD CONSTRAINT job_batches_new_pkey PRIMARY KEY (batch_id);


--
-- Name: job_batches_partitioned job_batches_partitioned_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_batches_partitioned
    ADD CONSTRAINT job_batches_partitioned_pkey PRIMARY KEY (id, created_at);


--
-- Name: job_categories job_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_categories
    ADD CONSTRAINT job_categories_pkey PRIMARY KEY (id);


--
-- Name: job_tags job_tags_name_fa_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_tags
    ADD CONSTRAINT job_tags_name_fa_key UNIQUE (name_fa);


--
-- Name: job_tags job_tags_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_tags
    ADD CONSTRAINT job_tags_pkey PRIMARY KEY (id);


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
-- Name: work_types work_types_name_fa_key; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.work_types
    ADD CONSTRAINT work_types_name_fa_key UNIQUE (name_fa);


--
-- Name: work_types work_types_pkey; Type: CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.work_types
    ADD CONSTRAINT work_types_pkey PRIMARY KEY (id);


--
-- Name: idx_companies_name_en; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_companies_name_en ON public.companies USING btree (name_en);


--
-- Name: idx_companies_name_fa; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_companies_name_fa ON public.companies USING btree (name_fa);


--
-- Name: idx_job_batches_partitioned_created_at; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_job_batches_partitioned_created_at ON ONLY public.job_batches_partitioned USING btree (created_at);


--
-- Name: idx_job_batches_partitioned_site; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_job_batches_partitioned_site ON ONLY public.job_batches_partitioned USING btree (site);


--
-- Name: idx_job_batches_partitioned_status; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_job_batches_partitioned_status ON ONLY public.job_batches_partitioned USING btree (status);


--
-- Name: idx_job_categories_name_fa_gin; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_job_categories_name_fa_gin ON public.job_categories USING gin (to_tsvector('simple'::regconfig, name_fa));


--
-- Name: idx_job_categories_parent_id; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_job_categories_parent_id ON public.job_categories USING btree (parent_id);


--
-- Name: idx_job_tags_name_fa; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_job_tags_name_fa ON public.job_tags USING btree (name_fa);


--
-- Name: idx_job_tags_name_fa_gin; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_job_tags_name_fa_gin ON public.job_tags USING gin (to_tsvector('simple'::regconfig, name_fa));


--
-- Name: idx_locations_name_fa_gin; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_locations_name_fa_gin ON public.locations USING gin (to_tsvector('simple'::regconfig, name_fa));


--
-- Name: idx_locations_parent_id; Type: INDEX; Schema: public; Owner: jobuser
--

CREATE INDEX idx_locations_parent_id ON public.locations USING btree (parent_id);


--
-- Name: companies update_companies_updated_at; Type: TRIGGER; Schema: public; Owner: jobuser
--

CREATE TRIGGER update_companies_updated_at BEFORE UPDATE ON public.companies FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();


--
-- Name: job_categories job_categories_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.job_categories
    ADD CONSTRAINT job_categories_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.job_categories(id);


--
-- Name: locations locations_parent_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: jobuser
--

ALTER TABLE ONLY public.locations
    ADD CONSTRAINT locations_parent_id_fkey FOREIGN KEY (parent_id) REFERENCES public.locations(id);


--
-- Name: SCHEMA public; Type: ACL; Schema: -; Owner: pg_database_owner
--

GRANT USAGE ON SCHEMA public TO readonly_user;
GRANT USAGE ON SCHEMA public TO app_user;
GRANT USAGE ON SCHEMA public TO cron_user;


--
-- Name: FUNCTION maintain_partitions(); Type: ACL; Schema: public; Owner: jobuser
--

GRANT ALL ON FUNCTION public.maintain_partitions() TO cron_user;


--
-- Name: TABLE companies; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.companies TO readonly_user;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.companies TO app_user;


--
-- Name: TABLE job_batches_new; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_new TO readonly_user;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_new TO app_user;


--
-- Name: TABLE job_batches_partitioned; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_batches_partitioned TO readonly_user;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_batches_partitioned TO app_user;


--
-- Name: SEQUENCE job_batches_partitioned_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON SEQUENCE public.job_batches_partitioned_id_seq TO readonly_user;
GRANT SELECT,USAGE ON SEQUENCE public.job_batches_partitioned_id_seq TO app_user;


--
-- Name: TABLE job_categories; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_categories TO readonly_user;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_categories TO app_user;


--
-- Name: TABLE job_tags; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.job_tags TO readonly_user;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.job_tags TO app_user;


--
-- Name: SEQUENCE job_tags_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON SEQUENCE public.job_tags_id_seq TO readonly_user;
GRANT SELECT,USAGE ON SEQUENCE public.job_tags_id_seq TO app_user;


--
-- Name: TABLE locations; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.locations TO readonly_user;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.locations TO app_user;


--
-- Name: SEQUENCE locations_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON SEQUENCE public.locations_id_seq TO readonly_user;
GRANT SELECT,USAGE ON SEQUENCE public.locations_id_seq TO app_user;


--
-- Name: TABLE schema_version; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.schema_version TO readonly_user;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.schema_version TO app_user;


--
-- Name: SEQUENCE schema_version_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON SEQUENCE public.schema_version_id_seq TO readonly_user;
GRANT SELECT,USAGE ON SEQUENCE public.schema_version_id_seq TO app_user;


--
-- Name: TABLE work_types; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON TABLE public.work_types TO readonly_user;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.work_types TO app_user;


--
-- Name: SEQUENCE work_types_id_seq; Type: ACL; Schema: public; Owner: jobuser
--

GRANT SELECT ON SEQUENCE public.work_types_id_seq TO readonly_user;
GRANT SELECT,USAGE ON SEQUENCE public.work_types_id_seq TO app_user;


--
-- Name: DEFAULT PRIVILEGES FOR SEQUENCES; Type: DEFAULT ACL; Schema: public; Owner: jobuser
--

ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT SELECT,USAGE ON SEQUENCES  TO jobuser;
ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT SELECT ON SEQUENCES  TO readonly_user;


--
-- Name: DEFAULT PRIVILEGES FOR TABLES; Type: DEFAULT ACL; Schema: public; Owner: jobuser
--

ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT SELECT,INSERT,DELETE,UPDATE ON TABLES  TO jobuser;
ALTER DEFAULT PRIVILEGES FOR ROLE jobuser IN SCHEMA public GRANT SELECT ON TABLES  TO readonly_user;


--
-- PostgreSQL database dump complete
--

