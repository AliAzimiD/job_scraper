"""
Job Scraper Application

A Flask application for scraping and displaying job listings.
"""
import os
from datetime import datetime
from flask import Flask, render_template_string, jsonify, request

def create_app():
    """Application factory pattern."""
    app = Flask(__name__)
    
    # Configure from environment variables
    app.config['SECRET_KEY'] = os.environ.get('SECRET_KEY', 'dev-key-for-testing')
    app.config['DATABASE_URL'] = os.environ.get('DATABASE_URL', 'sqlite:///jobscraper.db')
    
    # Initialize database
    from .db import init_db
    init_db(app)
    
    # Register routes
    
    @app.route('/')
    def index():
        """Home page."""
        return render_template_string("""
        <!DOCTYPE html>
        <html>
        <head>
            <title>Job Scraper</title>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
                body {
                    font-family: 'Segoe UI', Tahoma, sans-serif;
                    margin: 0;
                    padding: 20px;
                    background-color: #f7f9fc;
                    color: #333;
                }
                .container {
                    max-width: 1200px;
                    margin: 0 auto;
                    background-color: white;
                    padding: 30px;
                    border-radius: 8px;
                    box-shadow: 0 2px 10px rgba(0,0,0,0.1);
                }
                header {
                    border-bottom: 2px solid #eaeaea;
                    padding-bottom: 20px;
                    margin-bottom: 30px;
                }
                h1 {
                    color: #2c5282;
                    margin-top: 0;
                }
                .stats {
                    display: flex;
                    justify-content: space-between;
                    flex-wrap: wrap;
                    margin-bottom: 30px;
                }
                .stat-card {
                    background-color: #ebf4ff;
                    padding: 20px;
                    border-radius: 8px;
                    flex: 1;
                    margin: 10px;
                    min-width: 200px;
                    box-shadow: 0 2px 5px rgba(0,0,0,0.05);
                }
                .stat-card h3 {
                    margin-top: 0;
                    color: #4a5568;
                }
                .stat-card p {
                    font-size: 2em;
                    font-weight: bold;
                    margin: 10px 0;
                    color: #2b6cb0;
                }
                footer {
                    margin-top: 40px;
                    padding-top: 20px;
                    border-top: 1px solid #eaeaea;
                    text-align: center;
                    color: #718096;
                    font-size: 0.9em;
                }
            </style>
        </head>
        <body>
            <div class="container">
                <header>
                    <h1>Job Scraper Dashboard</h1>
                    <p>Welcome to the Job Scraper application. This dashboard provides an overview of the latest job listings.</p>
                </header>
                
                <div class="stats">
                    <div class="stat-card">
                        <h3>Total Jobs</h3>
                        <p>1,245</p>
                    </div>
                    <div class="stat-card">
                        <h3>Jobs Added Today</h3>
                        <p>42</p>
                    </div>
                    <div class="stat-card">
                        <h3>Total Sources</h3>
                        <p>5</p>
                    </div>
                    <div class="stat-card">
                        <h3>Last Update</h3>
                        <p style="font-size: 1.2em;">{{ current_time }}</p>
                    </div>
                </div>
                
                <div>
                    <h2>Recent Jobs</h2>
                    <p>Here you would see a list of the most recently added jobs from multiple sources.</p>
                </div>
                
                <footer>
                    <p>© {{ current_year }} Job Scraper Application | Developed with Flask and PostgreSQL</p>
                </footer>
            </div>
        </body>
        </html>
        """, current_time=datetime.now().strftime("%Y-%m-%d %H:%M"), current_year=datetime.now().year)
    
    @app.route('/api/jobs')
    def api_jobs():
        """API endpoint to get job listings."""
        return jsonify({
            "total": 1245,
            "jobs": [
                {
                    "id": 1,
                    "title": "Senior Software Engineer",
                    "company": "TechCorp",
                    "location": "Remote",
                    "posted_date": "2023-03-20"
                },
                {
                    "id": 2,
                    "title": "Data Scientist",
                    "company": "DataAnalytics Inc",
                    "location": "New York, NY",
                    "posted_date": "2023-03-21"
                },
                {
                    "id": 3,
                    "title": "DevOps Engineer",
                    "company": "CloudSystems",
                    "location": "San Francisco, CA",
                    "posted_date": "2023-03-22"
                }
            ]
        })
    
    @app.route('/health')
    def health():
        """Health check endpoint."""
        return jsonify({
            "status": "healthy",
            "version": "1.0.0",
            "timestamp": datetime.now().isoformat()
        })
    
    return app

if __name__ == '__main__':
    app = create_app()
    app.run(host='0.0.0.0', port=int(os.environ.get('PORT', 5000)), debug=False)
