# Database Component Documentation

The database component of the Job Scraper application is responsible for managing database connections, sessions, models, and providing an interface for other components to interact with the database.

## Core Components

### 1. Database Manager (`app/db/manager.py`)

The `DatabaseManager` class provides a centralized interface for database operations with the following features:

- **Connection Management**: Handles connection pooling, reconnection, and session creation
- **Configuration**: Loads database configuration from environment variables or YAML files
- **Error Handling**: Provides robust error handling for database operations
- **Health Checks**: Implements health check functionality for monitoring
- **Context Manager Support**: Can be used with Python's `with` statement for automatic resource cleanup

#### Usage Example

```python
from app.db.manager import DatabaseManager

# Create database manager
db_manager = DatabaseManager(config_path="config/app_config.yaml")

# Get a session
session = db_manager.get_session()

try:
    # Use session for database operations
    jobs = session.query(Job).filter_by(still_active=True).all()
    print(f"Found {len(jobs)} active jobs")
    
    # Commit changes
    session.commit()
finally:
    # Always close the session
    session.close()

# Health check
status, version = db_manager.health_check()
print(f"Database status: {'OK' if status else 'ERROR'}, version: {version}")

# When done, close all connections
db_manager.close()
```

### 2. Database Models (`app/db/models.py`)

The models define the database schema using SQLAlchemy ORM with the following main entities:

- **Job**: Represents a job posting with details like title, company, location, salary, etc.
- **Tag**: Represents a tag/skill that can be associated with jobs
- **ScraperSearch**: Represents a search configuration for the scraper
- **SearchResult**: Association table linking jobs to the searches that found them
- **ScraperRun**: Tracks the execution of scraper runs including statistics

#### Model Relationships

- Jobs have many-to-many relationship with Tags through the `job_tags` association table
- Jobs have many-to-many relationship with ScraperSearches through the `search_results` association table
- ScraperRun references a ScraperSearch to track which search configuration was used

### 3. Database Migrations (`app/db/migrations/`)

The migrations system uses Alembic to manage database schema changes with the following components:

- **alembic.ini**: Configuration file for Alembic
- **env.py**: Environment setup for running migrations
- **script.py.mako**: Template for migration scripts
- **versions/**: Directory containing migration script files

#### Managing Migrations

The application includes a script at `scripts/manage_migrations.py` to handle common migration tasks:

```bash
# Initialize migrations
python scripts/manage_migrations.py init

# Create a new migration (auto-detects changes)
python scripts/manage_migrations.py create "add user table"

# Upgrade to the latest version
python scripts/manage_migrations.py upgrade

# Downgrade to a specific version
python scripts/manage_migrations.py downgrade abc123def456

# Show migration history
python scripts/manage_migrations.py history

# Show current revision
python scripts/manage_migrations.py current
```

## Database Schema

### Tables

#### `jobs`

| Column | Type | Description |
|--------|------|-------------|
| id | Integer (PK) | Primary key |
| source_id | String | ID from the source website |
| title | String | Job title |
| company | String | Company name |
| location | String | Job location |
| description | Text | Job description |
| url | String | URL to the job posting |
| salary_min | Float | Minimum salary |
| salary_max | Float | Maximum salary |
| salary_currency | String | Currency for salary |
| remote | Boolean | Whether the job is remote |
| job_type | String | Type of job (full-time, part-time, contract) |
| experience_level | String | Required experience level |
| posted_date | DateTime | When the job was posted |
| created_at | DateTime | When the record was created |
| updated_at | DateTime | When the record was last updated |
| source_website | String | Source website name |
| still_active | Boolean | Whether the job is still active |
| last_check_date | DateTime | When the job was last verified |
| metadata | JSON | Additional metadata |

#### `tags`

| Column | Type | Description |
|--------|------|-------------|
| id | Integer (PK) | Primary key |
| name | String | Tag name |
| description | String | Tag description |
| created_at | DateTime | When the tag was created |

#### `job_tags` (Association Table)

| Column | Type | Description |
|--------|------|-------------|
| job_id | Integer (FK) | Foreign key to jobs table |
| tag_id | Integer (FK) | Foreign key to tags table |

#### `scraper_searches`

| Column | Type | Description |
|--------|------|-------------|
| id | Integer (PK) | Primary key |
| query | String | Search query |
| location | String | Location to search |
| source_website | String | Source website to search |
| job_type | String | Type of jobs to search for |
| remote_only | Boolean | Whether to search for remote jobs only |
| frequency | String | How often to run the search |
| last_run | DateTime | When the search was last run |
| is_active | Boolean | Whether the search is active |
| created_at | DateTime | When the search was created |
| updated_at | DateTime | When the search was last updated |

#### `search_results` (Association Table)

| Column | Type | Description |
|--------|------|-------------|
| search_id | Integer (FK) | Foreign key to scraper_searches table |
| job_id | Integer (FK) | Foreign key to jobs table |
| found_date | DateTime | When the job was found |
| relevance_score | Float | Relevance score |

#### `scraper_runs`

| Column | Type | Description |
|--------|------|-------------|
| id | Integer (PK) | Primary key |
| search_id | Integer (FK) | Foreign key to scraper_searches table |
| start_time | DateTime | When the run started |
| end_time | DateTime | When the run ended |
| status | String | Run status |
| jobs_found | Integer | Number of jobs found |
| jobs_added | Integer | Number of jobs added |
| error_message | Text | Error message if the run failed |
| run_id | String | Unique run identifier |

## Indexes

The database schema includes the following indexes for performance optimization:

- `jobs` table:
  - `idx_jobs_source_website`: On `source_website` for filtering by source
  - `idx_jobs_still_active`: On `still_active` for filtering active jobs
  - `idx_jobs_posted_date`: On `posted_date` for sorting and filtering by date
  - `idx_jobs_location`: On `location` for location-based searches
  - `idx_jobs_job_type`: On `job_type` for filtering by job type
  - `idx_jobs_experience_level`: On `experience_level` for filtering by experience

- `job_tags` table:
  - `idx_job_tags_job_id`: On `job_id` for fast job-to-tag lookups
  - `idx_job_tags_tag_id`: On `tag_id` for fast tag-to-job lookups

- `scraper_searches` table:
  - `idx_scraper_searches_source_website`: On `source_website` for filtering by source
  - `idx_scraper_searches_is_active`: On `is_active` for finding active searches

- `search_results` table:
  - `idx_search_results_search_id`: On `search_id` for finding jobs by search
  - `idx_search_results_job_id`: On `job_id` for finding searches by job
  - `idx_search_results_found_date`: On `found_date` for chronological sorting

- `scraper_runs` table:
  - `idx_scraper_runs_search_id`: On `search_id` for finding runs by search
  - `idx_scraper_runs_status`: On `status` for filtering by status
  - `idx_scraper_runs_start_time`: On `start_time` for chronological sorting
  - `idx_scraper_runs_run_id`: On `run_id` for finding specific runs

## Unique Constraints

The database schema includes the following unique constraints:

- `jobs` table:
  - `unique_job_source`: On (`source_id`, `source_website`) to prevent duplicate jobs

- `tags` table:
  - Unique constraint on `name` to prevent duplicate tags

- `scraper_searches` table:
  - `unique_search_params`: On (`query`, `location`, `source_website`, `job_type`, `remote_only`) to prevent duplicate searches

## Best Practices

When working with the database component:

1. **Use session management**:

   ```python
   session = db_manager.get_session()
   try:
       # Database operations
       session.commit()
   except Exception:
       session.rollback()
       raise
   finally:
       session.close()
   ```

2. **Use transactions for multiple operations**:

   ```python
   with session.begin():
       # Multiple database operations that should be atomic
       session.add(job)
       session.add(tag)
   ```

3. **Use batch operations for large datasets**:

   ```python
   # Add in batches of 100
   for i, job in enumerate(jobs):
       session.add(job)
       if i % 100 == 0:
           session.commit()
   # Commit any remaining
   session.commit()
   ```

4. **Validate input data before database operations**:

   ```python
   @validates('url')
   def validate_url(self, key, url):
       if not url or len(url) > 512:
           raise ValueError("URL must be provided and be no longer than 512 characters")
       return url
   ```

5. **Use appropriate SQLAlchemy query methods**:

   ```python
   # Good - efficient queries
   job = session.query(Job).filter_by(id=job_id).first()
   
   # Good - pagination
   page = 1
   page_size = 25
   jobs = session.query(Job).order_by(Job.posted_date.desc()).offset((page-1)*page_size).limit(page_size).all()
   ```

6. **Always close connections when done**:

   ```python
   # Using context manager
   with DatabaseManager() as db_manager:
       # Database operations
   
   # Or explicitly
   db_manager = DatabaseManager()
   try:
       # Database operations
   finally:
       db_manager.close()
   ```
