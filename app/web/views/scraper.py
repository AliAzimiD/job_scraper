"""
Scraper views blueprint for the Job Scraper application.

This module contains the routes for scraper operations,
including starting, stopping, and monitoring scraper jobs.
"""

from flask import Blueprint, render_template, jsonify, redirect, url_for, flash, current_app

# Create blueprint
scraper_bp = Blueprint('scraper', __name__)


@scraper_bp.route('/status')
def status():
    """
    Render the scraper status page.
    
    Returns:
        Rendered status template
    """
    return render_template('status.html')


@scraper_bp.route('/history')
def history():
    """
    Render the scraper history page.
    
    Returns:
        Rendered history template
    """
    # In a real application, you would fetch scraper history from the database
    scraper_runs = []
    
    return render_template('scraper/history.html', scraper_runs=scraper_runs)


@scraper_bp.route('/config')
def config():
    """
    Render the scraper configuration page.
    
    Returns:
        Rendered configuration template
    """
    return render_template('scraper/config.html') 