import json
from typing import Dict, Any, List, Optional
from datetime import datetime

from flask import Blueprint, request, jsonify, current_app, Response
from werkzeug.exceptions import NotFound, BadRequest, Unauthorized

from ...log_setup import get_logger
from ...utils.auth import api_auth_required
from ...models.job import Job

# Get logger for API endpoints
logger = get_logger("api")

# Create blueprint
api_bp = Blueprint('api', __name__)

@api_bp.route('/health', methods=['GET'])
def health_check():
    """
    Health check endpoint for monitoring systems.
    """
    try:
        # Check database connection
        db_service = current_app.db_service
        db_status = db_service.check_connection()
        
        # Get app version if available
        version = getattr(current_app, 'version', 'unknown')
        
        # Get scraper status
        scraper_service = current_app.scraper_service
        scraper_status = scraper_service.get_status() if scraper_service else {"status": "unknown"}
        
        # Build health response
        health_data = {
            "status": "healthy" if db_status else "unhealthy",
            "version": version,
            "timestamp": datetime.now().isoformat(),
            "services": {
                "database": "connected" if db_status else "disconnected",
                "scraper": scraper_status.get("status", "unknown")
            }
        }
        
        status_code = 200 if db_status else 503
        return jsonify(health_data), status_code
        
    except Exception as e:
        logger.error(f"Health check failed: {e}")
        return jsonify({
            "status": "unhealthy",
            "error": str(e),
            "timestamp": datetime.now().isoformat()
        }), 503

@api_bp.route('/jobs', methods=['GET'])
@api_auth_required
def get_jobs():
    """
    Get list of jobs with filtering options.
    """
    try:
        # Parse query parameters for filtering
        params = request.args
        
        # Parse pagination parameters
        limit = min(int(params.get('limit', 100)), 1000)  # Cap at 1000
        offset = int(params.get('offset', 0))
        
        # Build filters dictionary
        filters = {}
        if 'date_from' in params:
            filters['date_from'] = params.get('date_from')
        if 'date_to' in params:
            filters['date_to'] = params.get('date_to')
        if 'keywords' in params:
            filters['keywords'] = params.get('keywords')
        if 'company' in params:
            filters['company'] = params.get('company')
        if 'location' in params:
            filters['location'] = params.get('location')
        if 'job_title' in params:
            filters['job_title'] = params.get('job_title')
            
        # Get jobs from repository
        job_repository = current_app.job_repository
        jobs = job_repository.get_filtered_jobs(
            filters=filters,
            limit=limit,
            offset=offset
        )
        
        # Count total matching jobs for pagination info
        total_count = job_repository.count_filtered_jobs(filters=filters)
        
        # Convert jobs to dictionaries
        job_dicts = [job.to_dict() for job in jobs]
        
        # Build response with pagination metadata
        response = {
            "total": total_count,
            "limit": limit,
            "offset": offset,
            "count": len(job_dicts),
            "data": job_dicts
        }
        
        return jsonify(response)
        
    except ValueError as e:
        logger.error(f"Invalid parameter in request: {e}")
        return jsonify({"error": f"Invalid parameter: {str(e)}"}), 400
    except Exception as e:
        logger.error(f"Error getting jobs: {e}")
        return jsonify({"error": f"Internal server error: {str(e)}"}), 500

@api_bp.route('/jobs/<job_id>', methods=['GET'])
@api_auth_required
def get_job(job_id):
    """
    Get a specific job by ID.
    """
    try:
        # Attempt to get the job
        job_repository = current_app.job_repository
        job = job_repository.get_job_by_id(job_id)
        
        if not job:
            raise NotFound(f"Job with ID {job_id} not found")
            
        # Return job data
        return jsonify(job.to_dict())
        
    except NotFound as e:
        return jsonify({"error": str(e)}), 404
    except Exception as e:
        logger.error(f"Error getting job {job_id}: {e}")
        return jsonify({"error": f"Internal server error: {str(e)}"}), 500

@api_bp.route('/jobs', methods=['POST'])
@api_auth_required
def create_job():
    """
    Create a new job entry.
    """
    try:
        # Check if request has JSON data
        if not request.is_json:
            raise BadRequest("Request must contain JSON data")
            
        # Get JSON data from request
        data = request.get_json()
        
        # Validate required fields
        required_fields = ['title', 'company', 'location', 'description', 'url']
        for field in required_fields:
            if field not in data:
                raise BadRequest(f"Missing required field: {field}")
                
        # Create Job object
        job = Job(
            id=None,  # Will be generated by database
            title=data['title'],
            company=data['company'],
            location=data['location'],
            description=data['description'],
            url=data['url'],
            salary=data.get('salary'),
            posted_date=data.get('posted_date'),
            job_type=data.get('job_type'),
            remote=data.get('remote', False),
            tags=data.get('tags', []),
            source=data.get('source', 'api'),
            created_at=datetime.now(),
            updated_at=datetime.now()
        )
        
        # Add job to database
        job_repository = current_app.job_repository
        job_id = job_repository.add_job(job)
        
        if not job_id:
            raise Exception("Failed to add job to database")
            
        # Get the newly created job
        job = job_repository.get_job_by_id(job_id)
        
        # Return the created job with 201 status code
        return jsonify(job.to_dict()), 201
        
    except BadRequest as e:
        return jsonify({"error": str(e)}), 400
    except Exception as e:
        logger.error(f"Error creating job: {e}")
        return jsonify({"error": f"Internal server error: {str(e)}"}), 500

@api_bp.route('/jobs/<job_id>', methods=['PUT', 'PATCH'])
@api_auth_required
def update_job(job_id):
    """
    Update an existing job. PUT replaces the entire job, PATCH updates fields.
    """
    try:
        # Check if request has JSON data
        if not request.is_json:
            raise BadRequest("Request must contain JSON data")
            
        # Get JSON data from request
        data = request.get_json()
        
        # Get job repository
        job_repository = current_app.job_repository
        
        # Check if job exists
        existing_job = job_repository.get_job_by_id(job_id)
        if not existing_job:
            raise NotFound(f"Job with ID {job_id} not found")
            
        # Update approach depends on HTTP method
        is_partial = request.method == 'PATCH'
        
        if is_partial:
            # For PATCH, update only provided fields
            job_dict = existing_job.to_dict()
            job_dict.update(data)
        else:
            # For PUT, validate required fields
            required_fields = ['title', 'company', 'location', 'description', 'url']
            for field in required_fields:
                if field not in data:
                    raise BadRequest(f"Missing required field: {field}")
            job_dict = data
            
        # Ensure ID remains the same
        job_dict['id'] = job_id
        
        # Set updated time
        job_dict['updated_at'] = datetime.now()
        
        # Create updated job object
        updated_job = Job(**job_dict)
        
        # Update in repository
        success = job_repository.update_job(updated_job)
        
        if not success:
            raise Exception(f"Failed to update job with ID {job_id}")
            
        # Get the updated job
        job = job_repository.get_job_by_id(job_id)
        
        return jsonify(job.to_dict())
        
    except BadRequest as e:
        return jsonify({"error": str(e)}), 400
    except NotFound as e:
        return jsonify({"error": str(e)}), 404
    except Exception as e:
        logger.error(f"Error updating job {job_id}: {e}")
        return jsonify({"error": f"Internal server error: {str(e)}"}), 500

@api_bp.route('/jobs/<job_id>', methods=['DELETE'])
@api_auth_required
def delete_job(job_id):
    """
    Delete a job by ID.
    """
    try:
        # Get job repository
        job_repository = current_app.job_repository
        
        # Check if job exists
        existing_job = job_repository.get_job_by_id(job_id)
        if not existing_job:
            raise NotFound(f"Job with ID {job_id} not found")
            
        # Delete job
        success = job_repository.delete_job(job_id)
        
        if not success:
            raise Exception(f"Failed to delete job with ID {job_id}")
            
        # Return success message with 204 status code
        return '', 204
        
    except NotFound as e:
        return jsonify({"error": str(e)}), 404
    except Exception as e:
        logger.error(f"Error deleting job {job_id}: {e}")
        return jsonify({"error": f"Internal server error: {str(e)}"}), 500

@api_bp.route('/jobs/stats', methods=['GET'])
@api_auth_required
def get_job_stats():
    """
    Get job statistics.
    """
    try:
        # Get job repository
        job_repository = current_app.job_repository
        
        # Get statistics
        stats = job_repository.get_job_statistics()
        
        return jsonify(stats)
        
    except Exception as e:
        logger.error(f"Error getting job statistics: {e}")
        return jsonify({"error": f"Internal server error: {str(e)}"}), 500

@api_bp.route('/search', methods=['GET', 'POST'])
@api_auth_required
def search_jobs():
    """
    Search jobs with more complex filters.
    Accepts both GET with query parameters and POST with JSON body.
    """
    try:
        # Get search parameters from request
        if request.method == 'POST':
            if not request.is_json:
                raise BadRequest("POST request must contain JSON data")
            search_params = request.get_json()
        else:  # GET
            search_params = request.args.to_dict(flat=False)
            
            # Convert parameters that should be lists
            list_params = ['tags', 'locations', 'companies', 'job_types']
            for param in list_params:
                if param in search_params:
                    # Already a list from to_dict(flat=False)
                    continue
                    
            # Convert boolean parameters
            bool_params = ['remote']
            for param in bool_params:
                if param in search_params:
                    # Convert string to boolean
                    value = search_params[param][0].lower()
                    search_params[param] = value in ('true', '1', 'yes')
        
        # Parse pagination parameters
        limit = min(int(search_params.get('limit', [100])[0]), 1000)  # Cap at 1000
        offset = int(search_params.get('offset', [0])[0])
        
        # Perform search
        job_repository = current_app.job_repository
        results, total_count = job_repository.search_jobs(
            search_params=search_params,
            limit=limit,
            offset=offset
        )
        
        # Convert results to dictionaries
        job_dicts = [job.to_dict() for job in results]
        
        # Build response with pagination metadata
        response = {
            "total": total_count,
            "limit": limit,
            "offset": offset,
            "count": len(job_dicts),
            "data": job_dicts
        }
        
        return jsonify(response)
        
    except BadRequest as e:
        return jsonify({"error": str(e)}), 400
    except ValueError as e:
        logger.error(f"Invalid parameter in search: {e}")
        return jsonify({"error": f"Invalid search parameter: {str(e)}"}), 400
    except Exception as e:
        logger.error(f"Error searching jobs: {e}")
        return jsonify({"error": f"Internal server error: {str(e)}"}), 500

# Error handlers
@api_bp.errorhandler(NotFound)
def handle_not_found(e):
    """Handle 404 errors."""
    return jsonify({"error": str(e)}), 404

@api_bp.errorhandler(BadRequest)
def handle_bad_request(e):
    """Handle 400 errors."""
    return jsonify({"error": str(e)}), 400

@api_bp.errorhandler(Unauthorized)
def handle_unauthorized(e):
    """Handle 401 errors."""
    return jsonify({"error": "Authentication required"}), 401

@api_bp.errorhandler(Exception)
def handle_exception(e):
    """Handle generic errors."""
    logger.error(f"Unhandled exception in API: {e}")
    return jsonify({"error": "Internal server error"}), 500 