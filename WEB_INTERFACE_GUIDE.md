# Job Scraper Web Interface Guide

The job scraper web interface provides a user-friendly way to interact with the job scraping application, monitor its status, manage data, and perform backups. This guide explains the main features and how to use them.

## Accessing the Web Interface

After running the application with `test_locally.sh`, the web interface can be accessed at:

**URL:** http://localhost:5000

## Dashboard

The dashboard is your home page, providing an overview of the job scraper's status and collected data.

### Features:

1. **Stats Overview**
   - Total Jobs: Number of jobs stored in the database
   - Jobs Today: Jobs collected on the current day
   - Last Scrape: Number of jobs from the most recent scraping operation
   - Backups: Number of available backup files

2. **Recent Jobs Table**
   - Displays the most recently collected jobs
   - Links to view job details or visit the original job posting

3. **Quick Search**
   - Search box for quickly finding jobs by keyword
   - Links to advanced search and latest jobs

4. **Scraper Controls**
   - Current status indicator (Running, Idle, Error)
   - Form to start a new scraping job with configurable page count
   - Button to stop a running scraper

5. **Latest Backup Information**
   - Details about the most recent backup
   - Quick links to download or restore from that backup

## Job Search

The new search interface provides powerful filtering and browsing capabilities for job data:

### Search Filters

1. **Keyword Search**
   - Search for specific terms in job titles and descriptions
   - Matches are ranked by relevance when using the relevance sort option

2. **Location Filter**
   - Find jobs in specific cities or regions
   - Matches against location data in job listings

3. **Company Filter**
   - Search for jobs from specific companies
   - Works with both English and other language company names

4. **Date Filters**
   - Filter jobs posted within the last 24 hours, 7 days, 30 days, or 3 months
   - Helps find the most recent opportunities

5. **Sort Options**
   - Date: Newest jobs first (default)
   - Relevance: Most relevant to your search terms
   - Company: Alphabetically by company name

6. **Pagination**
   - Control how many results to display per page
   - Navigate through pages of search results

### Search Results

- Each job card shows key information:
  - Job title with link to detailed view
  - Company name
  - Location and work type badges
  - Posting date
  - Brief description snippet
  - Links to the original posting and detailed view

### Job Details View

Clicking on a job title or the "Details" button opens a comprehensive view of the job:

1. **Job Information**
   - Full job title and company information
   - Location, work type, and other job details
   - Complete job description
   - Salary information (when available)

2. **Metadata**
   - Tags and categories
   - Posting date
   - Source information

3. **Actions**
   - Apply on the original website
   - Return to search results

### Export Search Results

Search results can be easily exported in multiple formats:

1. **Export Formats**
   - CSV: For spreadsheet applications
   - JSON: For data processing and APIs
   - Excel: For Microsoft Excel users

2. **Export Process**
   - Run a search with your desired filters
   - Choose an export format from the Export Results card
   - The file will be generated and downloaded automatically

## Data Management

### Export Data

The Export page allows you to export job data in various formats:

1. **Export Format Options**
   - JSON: Full data in JavaScript Object Notation format
   - CSV: Tabular data in Comma Separated Values format
   - Parquet: Columnar storage format for efficient processing
   - Excel: Spreadsheet format for Microsoft Excel

2. **Filter Options**
   - Date Range: Set specific date ranges for the data to export
   - Keywords: Filter by text found in job titles or descriptions
   - Record Limit: Control how many records to export

3. **Compression**
   - Option to compress output file to save space

After exporting, you can download the file directly from the browser.

### Import Data

The Import page allows you to upload previously exported job data:

1. **File Selection**
   - Upload previously exported data files (JSON, CSV, Parquet, Excel)
   - Supports compressed files (.zip, .gz)

2. **Import Options**
   - Batch Size: Control memory usage during import
   - Update Existing: Choose whether to update existing jobs or only add new ones

The system validates all imported data and ensures no duplicates are created.

## Scraper Configuration

The new Scraper Configuration page provides a user-friendly interface to adjust how the scraper operates:

### Configuration Sections

1. **Request Settings**
   - Max Pages: Maximum number of pages to scrape per run
   - Batch Size: Number of jobs to process in each batch
   - Request Timeout: How long to wait for API responses
   - User Agent: Browser identification string for requests

2. **Retry & Error Handling**
   - API Retry Count: Number of times to retry failed API requests
   - Retry Delay: Seconds to wait between retries
   - Database Retry Count: Number of times to retry database operations
   - Failure Threshold: Maximum number of failures before stopping

3. **Storage Options**
   - Save Raw Data Files: Whether to store raw JSON responses

### Using the Configuration Interface

1. Adjust settings according to your needs
2. Click "Save Configuration" to apply changes
3. Changes take effect immediately for new scraping operations

## Backup Management

### Create Backup

The Create Backup page allows you to save the current state of all job data:

1. **Backup Options**
   - Include Raw Files: Include the original scraper data files
   - Password Protection: Encrypt the backup with a password

2. **Process**
   - Click "Create Backup" to start the process
   - Wait for the backup to complete
   - You'll be redirected to the backups page when done

### Manage Backups

The Manage Backups page shows all available backups:

1. **Backup List**
   - Filename, creation date, size, and type for each backup
   - Actions: Download, Restore, Delete

2. **Download**
   - Save the backup file to your local machine

3. **Restore**
   - Choose which components to restore (database, files)
   - Enter password if the backup is protected
   - Start the restore process

4. **Delete**
   - Remove backups you no longer need

## Best Practices

1. **Regular Backups**
   - Create backups after significant data collection
   - Keep backups in multiple locations for important data

2. **Careful Imports**
   - Review import data before uploading
   - Start with small test imports to verify data quality

3. **Efficient Exports**
   - Use filters to create smaller, more focused data sets
   - Choose the right format for your needs:
     - JSON for completeness
     - CSV for readability and compatibility
     - Parquet for data science and analysis
     - Excel for spreadsheet users

4. **Resource Management**
   - Avoid starting multiple scraping jobs at once
   - For large data sets, increase batch sizes cautiously

5. **Scraper Configuration**
   - Increase retry counts in unstable network environments
   - Use smaller batch sizes for more frequent progress updates
   - Set failure threshold higher during development, lower in production

6. **Search Tips**
   - Use simple keywords for broader results
   - Combine multiple filters for more specific searches
   - Change sort order based on your priorities (newest jobs vs. best match)

## Troubleshooting

- **Slow Operations**: For large datasets, exports, imports, and backups may take time. Be patient.
- **Import Errors**: Check that your file format matches what the system expects.
- **Backup Password**: If you forget a backup password, you cannot restore that backup.
- **Web Interface Not Responding**: Check that all containers are running with `docker ps`.
- **Search Issues**: If searches are slow, try using more specific filters and reducing the results per page.
- **Configuration Changes Not Applied**: Make sure to save your configuration and restart any running scraper jobs.

## Analytics Dashboard

The Analytics Dashboard provides advanced data visualization and exploration capabilities powered by Apache Superset. This powerful analytics platform allows you to gain deeper insights from your job data.

### Accessing Analytics

1. **Navigation**: Click on "Analytics" in the main navigation menu
2. **Dashboard Overview**: You'll see a list of available dashboards and an embedded view of the main dashboard

### Features

1. **Interactive Dashboards**
   - Pre-built dashboards with visualizations of key job metrics
   - Interactive filtering and drill-down capabilities
   - Time-based analysis of job posting trends

2. **Data Exploration**
   - View distributions of jobs by location, category, and company
   - Analyze salary ranges and compensation trends
   - Track job posting volume over time

3. **Custom SQL Analysis**
   - Open SQL Lab to write custom queries
   - Create your own visualizations from query results
   - Save and share your custom analyses

### Using the Dashboards

1. **Job Market Trends**
   - Shows job posting volume over time
   - Distribution of jobs by location and category
   - Top companies by job posting count

2. **Salary Analysis**
   - Salary distributions by job category
   - Geographic salary comparisons
   - Trend analysis of compensation over time

### Direct Superset Access

For more advanced analytics:

1. Click the "Open Superset Dashboard" button to access the full Superset interface
2. Login with the provided credentials (default: admin/admin)
3. Explore the full range of Superset features:
   - Create custom dashboards
   - Design new visualizations
   - Set up alerts and scheduled reports
   - Share insights with team members

### Best Practices

1. **Filtering**: Use dashboard filters to focus on specific date ranges, locations, or job categories
2. **Exporting**: Export visualizations or data for use in presentations or reports
3. **Refreshing**: Data is automatically updated, but you can manually refresh dashboards to see the latest data
4. **Custom Analysis**: For complex analysis, use SQL Lab to write custom queries 