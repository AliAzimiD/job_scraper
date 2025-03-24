-- Add derived columns for tags, job board, location, and categories
ALTER TABLE IF EXISTS public.jobs
  ADD COLUMN IF NOT EXISTS tag_no_experience INT DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tag_remote INT DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tag_part_time INT DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tag_internship INT DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tag_military_exemption INT DEFAULT 0,
  ADD COLUMN IF NOT EXISTS jobBoard_titleEn TEXT,
  ADD COLUMN IF NOT EXISTS jobBoard_titleFa TEXT,
  ADD COLUMN IF NOT EXISTS primary_city TEXT,
  ADD COLUMN IF NOT EXISTS work_type TEXT,
  ADD COLUMN IF NOT EXISTS category TEXT,
  ADD COLUMN IF NOT EXISTS parent_cat TEXT,
  ADD COLUMN IF NOT EXISTS sub_cat TEXT;

-- Create trigger function to automatically populate derived columns
CREATE OR REPLACE FUNCTION fn_update_derived_columns()
RETURNS TRIGGER AS
$$
BEGIN
    -------------------------------------------------------------------
    -- Tags logic
    -------------------------------------------------------------------
    IF NEW.tags IS NOT NULL THEN

        -- tag_no_experience
        NEW.tag_no_experience := CASE 
            WHEN EXISTS (SELECT 1 
                         FROM jsonb_array_elements_text(NEW.tags) AS t
                         WHERE t = 'بدون نیاز به سابقه')
            THEN 1
            ELSE 0
        END;
        
        -- tag_remote
        NEW.tag_remote := CASE 
            WHEN EXISTS (SELECT 1 
                         FROM jsonb_array_elements_text(NEW.tags) AS t
                         WHERE t = 'دورکاری')
            THEN 1
            ELSE 0
        END;

        -- tag_part_time
        NEW.tag_part_time := CASE 
            WHEN EXISTS (SELECT 1 
                         FROM jsonb_array_elements_text(NEW.tags) AS t
                         WHERE t = 'پاره وقت')
            THEN 1
            ELSE 0
        END;

        -- tag_internship
        NEW.tag_internship := CASE 
            WHEN EXISTS (SELECT 1 
                         FROM jsonb_array_elements_text(NEW.tags) AS t
                         WHERE t = 'کارآموزی')
            THEN 1
            ELSE 0
        END;

        -- tag_military_exemption
        NEW.tag_military_exemption := CASE 
            WHEN EXISTS (SELECT 1 
                         FROM jsonb_array_elements_text(NEW.tags) AS t
                         WHERE t = 'امریه سربازی')
            THEN 1
            ELSE 0
        END;

    END IF;

    -------------------------------------------------------------------
    -- jobBoard_titleEn & jobBoard_titleFa logic
    -------------------------------------------------------------------
    IF NEW.raw_data ? 'jobBoard' THEN
        NEW.jobBoard_titleEn := NEW.raw_data->'jobBoard'->>'titleEn';
        NEW.jobBoard_titleFa := NEW.raw_data->'jobBoard'->>'titleFa';
    END IF;

    -------------------------------------------------------------------
    -- primary_city (from locations)
    -------------------------------------------------------------------
    IF NEW.locations IS NOT NULL
       AND jsonb_typeof(NEW.locations) = 'array' THEN
        NEW.primary_city := (
            SELECT elem->'city'->>'titleEn'
            FROM jsonb_array_elements(NEW.locations) AS elem
            LIMIT 1
        );
    END IF;

    -------------------------------------------------------------------
    -- work_type (from work_types)
    -------------------------------------------------------------------
    IF NEW.work_types IS NOT NULL
       AND jsonb_typeof(NEW.work_types) = 'array' THEN
        NEW.work_type := (
            SELECT elem->>'titleEn'
            FROM jsonb_array_elements(NEW.work_types) AS elem
            LIMIT 1
        );
    END IF;

    -------------------------------------------------------------------
    -- category, parent_cat, sub_cat (from job_post_categories)
    -------------------------------------------------------------------
    IF NEW.job_post_categories IS NOT NULL
       AND jsonb_typeof(NEW.job_post_categories) = 'array'
       AND jsonb_array_length(NEW.job_post_categories) > 0 THEN

        -- If there's only one element in the array, that becomes "category"
        -- If there are at least two, the first is "parent_cat" and the second is "sub_cat" (and also "category").
        IF jsonb_array_length(NEW.job_post_categories) = 1 THEN
            NEW.category := NEW.job_post_categories->0->>'titleEn';
            NEW.parent_cat := NULL; -- or same as category if you prefer
            NEW.sub_cat := NULL;
        ELSIF jsonb_array_length(NEW.job_post_categories) >= 2 THEN
            NEW.category := NEW.job_post_categories->1->>'titleEn';
            NEW.parent_cat := NEW.job_post_categories->0->>'titleEn';
            NEW.sub_cat := NEW.job_post_categories->1->>'titleEn';
        END IF;
    END IF;

    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

-- Create trigger that calls this function
DROP TRIGGER IF EXISTS trg_update_derived_columns ON public.jobs;

CREATE TRIGGER trg_update_derived_columns
BEFORE INSERT OR UPDATE
ON public.jobs
FOR EACH ROW
EXECUTE PROCEDURE fn_update_derived_columns();

-- One-time update for existing data (only if there are rows)
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.jobs LIMIT 1) THEN
        EXECUTE 'UPDATE public.jobs SET updated_at = NOW() WHERE id IN (SELECT id FROM public.jobs)';
    END IF;
END $$; 