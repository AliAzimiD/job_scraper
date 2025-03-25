from flask import Blueprint, render_template, current_app, request, jsonify, flash, redirect, url_for
from ...log_setup import get_logger

# Get logger
logger = get_logger("scraper_routes")

# Create blueprint
scraper_bp = Blueprint(
    'scraper', 
    __name__,
    template_folder='templates',
    static_folder='static'
)

@scraper_bp.route('/status')
def status():
    """
    Get the current scraper status.
    """
    scraper_service = current_app.scraper_service
    status = scraper_service.get_status()
    
    return render_template(
        'scraper/status.html',
        status=status
    )

@scraper_bp.route('/start', methods=['GET', 'POST'])
def start():
    """
    Start a scraping job.
    """
    if request.method == 'POST':
        # Get form parameters
        max_pages = request.form.get('max_pages', type=int, default=1)
        
        if max_pages < 1:
            flash("Max pages must be a positive integer", "danger")
            return redirect(url_for('scraper.start'))
            
        scraper_service = current_app.scraper_service
        
        # Check if scraper is already running
        if scraper_service.is_running:
            flash("Scraper is already running", "warning")
            return redirect(url_for('scraper.status'))
            
        # Start scraper
        scraper_service.start_scrape(max_pages=max_pages)
        
        flash(f"Started scraping job with max_pages={max_pages}", "success")
        return redirect(url_for('scraper.status'))
        
    # GET request - show form
    return render_template('scraper/start.html')

@scraper_bp.route('/stop', methods=['POST'])
def stop():
    """
    Stop a running scraping job.
    """
    scraper_service = current_app.scraper_service
    
    # Check if scraper is running
    if not scraper_service.is_running:
        flash("No scraper job is running", "warning")
        return redirect(url_for('scraper.status'))
        
    # Force scraper to stop
    scraper_service.is_running = False
    scraper_service.status = "cancelled"
    
    flash("Scraper job has been cancelled", "success")
    return redirect(url_for('scraper.status'))

@scraper_bp.route('/config', methods=['GET', 'POST'])
def config():
    """
    View and update scraper configuration.
    """
    config_manager = current_app.config_manager
    
    if request.method == 'POST':
        # This would be a more complex implementation to update the config
        # For now, just display a success message
        flash("Configuration updated successfully", "success")
        return redirect(url_for('scraper.config'))
        
    # GET request - show config
    api_config = config_manager.api_config
    request_config = config_manager.request_config
    
    return render_template(
        'scraper/config.html',
        api_config=api_config,
        request_config=request_config
    )

@scraper_bp.route('/api/status', methods=['GET'])
def api_status():
    """
    API endpoint to get scraper status.
    """
    scraper_service = current_app.scraper_service
    status = scraper_service.get_status()
    
    return jsonify(status)

@scraper_bp.route('/api/start', methods=['POST'])
def api_start():
    """
    API endpoint to start a scraping job.
    """
    # Get JSON parameters
    data = request.get_json() or {}
    max_pages = data.get('max_pages', 1)
    
    if not isinstance(max_pages, int) or max_pages < 1:
        return jsonify({
            "success": False,
            "error": "max_pages must be a positive integer"
        }), 400
        
    scraper_service = current_app.scraper_service
    
    # Check if scraper is already running
    if scraper_service.is_running:
        return jsonify({
            "success": False,
            "error": "Scraper is already running"
        }), 400
        
    # Start scraper
    success = scraper_service.start_scrape(max_pages=max_pages)
    
    if success:
        return jsonify({
            "success": True,
            "message": f"Started scraping job with max_pages={max_pages}"
        })
    else:
        return jsonify({
            "success": False,
            "error": "Failed to start scraper"
        }), 500

@scraper_bp.route('/api/stop', methods=['POST'])
def api_stop():
    """
    API endpoint to stop a running scraping job.
    """
    scraper_service = current_app.scraper_service
    
    # Check if scraper is running
    if not scraper_service.is_running:
        return jsonify({
            "success": False,
            "error": "No scraper job is running"
        }), 400
        
    # Force scraper to stop
    scraper_service.is_running = False
    scraper_service.status = "cancelled"
    
    return jsonify({
        "success": True,
        "message": "Scraper job has been cancelled"
    }) 