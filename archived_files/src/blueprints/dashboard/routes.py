from flask import Blueprint, render_template, current_app, request, flash, redirect, url_for
from ...log_setup import get_logger

# Get logger
logger = get_logger("dashboard")

# Create blueprint
dashboard_bp = Blueprint(
    'dashboard', 
    __name__,
    template_folder='templates',
    static_folder='static'
)

@dashboard_bp.route('/')
@dashboard_bp.route('/dashboard')
def index():
    """
    Render the main dashboard page.
    Displays overall statistics and recent jobs.
    """
    # Get job count
    job_repository = current_app.job_repository
    job_count = job_repository.get_job_count()
    
    # Get recent jobs
    recent_jobs = job_repository.get_recent_jobs(limit=10)
    
    # Get scraper status
    scraper_service = current_app.scraper_service
    scraper_status = scraper_service.get_status()
    
    # Convert to template-friendly format
    scraper_stats = {
        "total_jobs": scraper_status.get("total_jobs_found", 0),
        "status": scraper_status.get("status", "idle"),
        "last_run": scraper_status.get("last_run", None),
        "new_jobs": scraper_status.get("new_jobs", 0)
    }
    
    # Get job statistics
    job_stats = job_repository.get_job_statistics()
    
    return render_template(
        'dashboard/index.html',
        job_count=job_count,
        scraper_stats=scraper_stats,
        recent_jobs=recent_jobs,
        job_stats=job_stats,
        scraper_running=scraper_status.get("is_running", False)
    )

@dashboard_bp.route('/statistics')
def statistics():
    """
    Render the statistics page.
    Displays detailed job statistics.
    """
    # Get job statistics
    job_repository = current_app.job_repository
    job_stats = job_repository.get_job_statistics()
    
    return render_template(
        'dashboard/statistics.html',
        job_stats=job_stats
    )

@dashboard_bp.route('/job/<job_id>')
def view_job(job_id):
    """
    Render the job details page.
    
    Args:
        job_id: ID of the job to view
    """
    # Get job details
    job_repository = current_app.job_repository
    job = job_repository.get_job_by_id(job_id)
    
    if not job:
        flash(f"Job not found with ID: {job_id}", "danger")
        return redirect(url_for('dashboard.index'))
    
    return render_template(
        'dashboard/job_details.html',
        job=job
    )

@dashboard_bp.route('/search')
def search():
    """
    Search for jobs with filters.
    Renders search results page.
    """
    # Get search parameters
    keywords = request.args.get('keywords', '')
    date_from = request.args.get('date_from', '')
    date_to = request.args.get('date_to', '')
    company = request.args.get('company', '')
    category = request.args.get('category', '')
    remote = request.args.get('remote') == 'on'
    no_experience = request.args.get('no_experience') == 'on'
    
    # Create filter dictionary
    filters = {}
    if keywords:
        filters['keywords'] = keywords
    if date_from:
        filters['date_from'] = date_from
    if date_to:
        filters['date_to'] = date_to
    if company:
        filters['company'] = company
    if category:
        filters['category'] = category
    if remote:
        filters['remote'] = True
    if no_experience:
        filters['no_experience'] = True
        
    # Get page and limit parameters
    page = request.args.get('page', 1, type=int)
    limit = request.args.get('limit', 20, type=int)
    offset = (page - 1) * limit
    
    # Get filtered jobs
    job_repository = current_app.job_repository
    jobs = job_repository.get_filtered_jobs(filters, limit=limit, offset=offset)
    
    # Get total count for pagination
    total_count = len(jobs)  # This is just an approximation
    total_pages = (total_count + limit - 1) // limit
    
    return render_template(
        'dashboard/search_results.html',
        jobs=jobs,
        filters=filters,
        page=page,
        limit=limit,
        total_pages=total_pages,
        total_count=total_count
    ) 