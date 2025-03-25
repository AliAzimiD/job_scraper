"""
Main views blueprint for the Job Scraper application.

This module contains the routes for the main pages of the application,
including the dashboard and index page.
"""

from datetime import datetime
from flask import Blueprint, render_template, current_app

main_bp = Blueprint('main', __name__)


@main_bp.context_processor
def inject_current_year():
    """Inject the current year into all templates."""
    return {'current_year': datetime.now().year}


@main_bp.route('/')
def index():
    """
    Render the index/dashboard page.
    
    Returns:
        Rendered dashboard template
    """
    return render_template('dashboard.html')


@main_bp.route('/status')
def status():
    """
    Render the status page.
    
    Returns:
        Rendered status template
    """
    return render_template('status.html')


@main_bp.route('/health')
def health():
    """
    Health check endpoint.
    
    Returns:
        JSON with health status
    """
    from flask import jsonify
    return jsonify({
        'status': 'ok',
        'timestamp': datetime.utcnow().isoformat()
    }) 