#!/bin/bash

# Script to set up the Job Scraper Admin Dashboard
set -e  # Exit on any error

echo "Setting up Job Scraper Admin Dashboard..."

# Define paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
PUBLIC_DIR="$ROOT_DIR/public"
ADMIN_DIR="$PUBLIC_DIR/admin"
LOGS_DIR="$ROOT_DIR/logs"

# Create necessary directories
echo "Creating necessary directories..."
mkdir -p "$PUBLIC_DIR"
mkdir -p "$ADMIN_DIR/css"
mkdir -p "$ADMIN_DIR/js"
mkdir -p "$LOGS_DIR"

# Install dependencies
echo "Installing dependencies..."
python_cmd=""
if command -v python3 &>/dev/null; then
    python_cmd="python3"
elif command -v python &>/dev/null; then
    python_cmd="python"
else
    echo "Error: Python is not installed. Please install Python 3."
    exit 1
fi

pip_cmd=""
if command -v pip3 &>/dev/null; then
    pip_cmd="pip3"
elif command -v pip &>/dev/null; then
    pip_cmd="pip"
else
    echo "Installing pip..."
    $python_cmd -m ensurepip --upgrade || {
        echo "Error: Failed to install pip. Please install pip manually."
        exit 1
    }
    pip_cmd="pip3"
fi

echo "Installing required packages..."
$pip_cmd install fastapi uvicorn python-multipart || {
    echo "Warning: Some packages may not have installed correctly."
    echo "You may need to install them manually:"
    echo "pip install fastapi uvicorn python-multipart"
}

# Create default CSS file if it doesn't exist
if [ ! -f "$ADMIN_DIR/css/admin.css" ]; then
    echo "Creating default CSS file..."
    cat > "$ADMIN_DIR/css/admin.css" << 'EOF'
/* Admin Dashboard Styles */
.dashboard-container {
    padding: 20px;
}

.card {
    transition: transform 0.2s, box-shadow 0.2s;
}

.card:hover {
    transform: translateY(-5px);
    box-shadow: 0 10px 20px rgba(0,0,0,0.1);
}

.status-active {
    animation: pulse 1.5s infinite;
}

@keyframes pulse {
    0% {
        opacity: 0.7;
    }
    50% {
        opacity: 1;
    }
    100% {
        opacity: 0.7;
    }
}

.log-viewer {
    font-family: monospace;
    background-color: #f8f9fa;
    padding: 10px;
    border-radius: 5px;
    height: 300px;
    overflow-y: auto;
}

.log-entry {
    margin-bottom: 5px;
}

@media (max-width: 768px) {
    .dashboard-container {
        padding: 10px;
    }
}
EOF
fi

# Create default JS file if it doesn't exist
if [ ! -f "$ADMIN_DIR/js/admin.js" ]; then
    echo "Creating default JS file..."
    cat > "$ADMIN_DIR/js/admin.js" << 'EOF'
// API Endpoints
const STATS_API = '/api/stats';
const LOGS_API = '/api/logs';
const CONFIG_API = '/api/config';
const START_SCRAPE_API = '/api/scrape/start';
const STOP_SCRAPE_API = '/api/scrape/stop';

// Refresh status information
async function refreshStatus() {
    try {
        showLoading('#status-card');
        const response = await fetch(STATS_API);
        if (!response.ok) throw new Error('Failed to fetch status');
        
        const data = await response.json();
        
        // Update status elements
        document.getElementById('scrape-status').textContent = data.is_running ? 'Running' : 'Idle';
        document.getElementById('scrape-status').className = data.is_running ? 
            'badge bg-success status-active' : 'badge bg-secondary';
        
        document.getElementById('last-scrape').textContent = data.last_scrape_time || 'Never';
        document.getElementById('total-jobs').textContent = data.total_jobs || '0';
        
        // Update recent jobs if available
        if (data.recent_jobs && Array.isArray(data.recent_jobs)) {
            updateRecentJobs(data.recent_jobs);
        }
        
        // Enable/disable buttons based on status
        document.getElementById('start-scrape-btn').disabled = data.is_running;
        document.getElementById('stop-scrape-btn').disabled = !data.is_running;
        
        hideLoading('#status-card');
    } catch (error) {
        console.error('Error refreshing status:', error);
        showError('#status-card', 'Failed to refresh status');
    }
}

// Update recent jobs table
function updateRecentJobs(jobs) {
    const tableBody = document.getElementById('recent-jobs-table').querySelector('tbody');
    tableBody.innerHTML = '';
    
    if (jobs.length === 0) {
        const row = document.createElement('tr');
        row.innerHTML = '<td colspan="4" class="text-center">No jobs found</td>';
        tableBody.appendChild(row);
        return;
    }
    
    jobs.slice(0, 5).forEach(job => {
        const row = document.createElement('tr');
        row.innerHTML = `
            <td>${job.title || 'N/A'}</td>
            <td>${job.company || 'N/A'}</td>
            <td>${job.location || 'N/A'}</td>
            <td>${job.date || 'N/A'}</td>
        `;
        tableBody.appendChild(row);
    });
}

// Refresh logs
async function refreshLogs() {
    try {
        showLoading('#logs-card');
        const response = await fetch(`${LOGS_API}?limit=100`);
        if (!response.ok) throw new Error('Failed to fetch logs');
        
        const data = await response.json();
        const logsContainer = document.getElementById('logs-container');
        
        logsContainer.innerHTML = '';
        if (data.logs && data.logs.length > 0) {
            data.logs.forEach(log => {
                const logEntry = document.createElement('div');
                logEntry.className = 'log-entry';
                logEntry.textContent = log;
                logsContainer.appendChild(logEntry);
            });
            
            // Auto-scroll to bottom
            logsContainer.scrollTop = logsContainer.scrollHeight;
        } else {
            logsContainer.innerHTML = '<div class="text-center">No logs available</div>';
        }
        
        hideLoading('#logs-card');
    } catch (error) {
        console.error('Error refreshing logs:', error);
        showError('#logs-card', 'Failed to refresh logs');
    }
}

// Refresh configuration
async function refreshConfig() {
    try {
        showLoading('#config-card');
        const response = await fetch(CONFIG_API);
        if (!response.ok) throw new Error('Failed to fetch configuration');
        
        const data = await response.json();
        const configContainer = document.getElementById('config-form');
        
        // Clear previous form fields
        configContainer.innerHTML = '';
        
        // Create form fields based on configuration
        if (data && Object.keys(data).length > 0) {
            Object.entries(data).forEach(([key, value]) => {
                const formGroup = document.createElement('div');
                formGroup.className = 'mb-3';
                
                const label = document.createElement('label');
                label.className = 'form-label';
                label.textContent = key.replace(/_/g, ' ').replace(/\b\w/g, l => l.toUpperCase());
                label.setAttribute('for', `config-${key}`);
                
                const input = document.createElement('input');
                input.type = typeof value === 'number' ? 'number' : 'text';
                input.className = 'form-control';
                input.id = `config-${key}`;
                input.name = key;
                input.value = value;
                
                formGroup.appendChild(label);
                formGroup.appendChild(input);
                configContainer.appendChild(formGroup);
            });
            
            // Add submit button
            const submitBtn = document.createElement('button');
            submitBtn.type = 'submit';
            submitBtn.className = 'btn btn-primary';
            submitBtn.textContent = 'Save Configuration';
            configContainer.appendChild(submitBtn);
        } else {
            configContainer.innerHTML = '<div class="alert alert-info">No configuration available</div>';
        }
        
        hideLoading('#config-card');
    } catch (error) {
        console.error('Error refreshing configuration:', error);
        showError('#config-card', 'Failed to refresh configuration');
    }
}

// Helper to show loading indicator
function showLoading(selector) {
    const container = document.querySelector(selector);
    if (container) {
        container.classList.add('loading');
        const spinner = document.querySelector(`${selector} .spinner`);
        if (spinner) spinner.style.display = 'block';
    }
}

// Helper to hide loading indicator
function hideLoading(selector) {
    const container = document.querySelector(selector);
    if (container) {
        container.classList.remove('loading');
        const spinner = document.querySelector(`${selector} .spinner`);
        if (spinner) spinner.style.display = 'none';
    }
}

// Helper to show error message
function showError(selector, message) {
    hideLoading(selector);
    const container = document.querySelector(selector);
    if (container) {
        const errorDiv = document.createElement('div');
        errorDiv.className = 'alert alert-danger mt-2 error-message';
        errorDiv.textContent = message;
        
        // Remove any existing error messages
        const existingError = container.querySelector('.error-message');
        if (existingError) container.removeChild(existingError);
        
        container.appendChild(errorDiv);
        
        // Auto-hide after 5 seconds
        setTimeout(() => {
            if (errorDiv.parentNode === container) {
                container.removeChild(errorDiv);
            }
        }, 5000);
    }
}

// Initialize on page load
document.addEventListener('DOMContentLoaded', function() {
    // Initial data load
    refreshStatus();
    refreshLogs();
    refreshConfig();
    
    // Setup refresh buttons
    document.getElementById('refresh-status-btn').addEventListener('click', refreshStatus);
    document.getElementById('refresh-logs-btn').addEventListener('click', refreshLogs);
    document.getElementById('refresh-config-btn').addEventListener('click', refreshConfig);
    
    // Setup start/stop buttons
    document.getElementById('start-scrape-btn').addEventListener('click', async function() {
        try {
            const response = await fetch(START_SCRAPE_API, {
                method: 'POST'
            });
            if (!response.ok) throw new Error('Failed to start scraping');
            refreshStatus();
        } catch (error) {
            console.error('Error starting scrape:', error);
            showError('#status-card', 'Failed to start scraping');
        }
    });
    
    document.getElementById('stop-scrape-btn').addEventListener('click', async function() {
        try {
            const response = await fetch(STOP_SCRAPE_API, {
                method: 'POST'
            });
            if (!response.ok) throw new Error('Failed to stop scraping');
            refreshStatus();
        } catch (error) {
            console.error('Error stopping scrape:', error);
            showError('#status-card', 'Failed to stop scraping');
        }
    });
    
    // Setup config form submission
    document.getElementById('config-form').addEventListener('submit', async function(e) {
        e.preventDefault();
        
        try {
            // Collect form data
            const formData = new FormData(this);
            const config = {};
            
            for (const [key, value] of formData.entries()) {
                // Convert to number if it looks like a number
                config[key] = !isNaN(value) && value !== '' ? Number(value) : value;
            }
            
            const response = await fetch(CONFIG_API, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify(config)
            });
            
            if (!response.ok) throw new Error('Failed to update configuration');
            
            // Show success message
            const successDiv = document.createElement('div');
            successDiv.className = 'alert alert-success mt-2';
            successDiv.textContent = 'Configuration updated successfully';
            this.appendChild(successDiv);
            
            // Auto-hide success message
            setTimeout(() => {
                if (successDiv.parentNode === this) {
                    this.removeChild(successDiv);
                }
            }, 3000);
            
            // Refresh config
            setTimeout(refreshConfig, 1000);
        } catch (error) {
            console.error('Error updating configuration:', error);
            showError('#config-card', 'Failed to update configuration');
        }
    });
    
    // Auto-refresh every 30 seconds
    setInterval(() => {
        refreshStatus();
        refreshLogs();
    }, 30000);
});
EOF
fi

# Create default HTML file if it doesn't exist
if [ ! -f "$ADMIN_DIR/index.html" ]; then
    echo "Creating default HTML file..."
    cat > "$ADMIN_DIR/index.html" << 'EOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Job Scraper Admin Dashboard</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" href="/static/admin/css/admin.css">
    <style>
        .card {
            margin-bottom: 20px;
        }
        .spinner {
            display: none;
            width: 2rem;
            height: 2rem;
        }
        .loading {
            position: relative;
        }
        .loading::after {
            content: "";
            position: absolute;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background: rgba(255,255,255,0.7);
            z-index: 1;
        }
    </style>
</head>
<body>
    <nav class="navbar navbar-expand-lg navbar-dark bg-primary">
        <div class="container-fluid">
            <a class="navbar-brand" href="#">Job Scraper Admin</a>
        </div>
    </nav>

    <div class="container dashboard-container mt-4">
        <div class="row">
            <!-- Status Panel -->
            <div class="col-md-6">
                <div class="card" id="status-card">
                    <div class="card-header d-flex justify-content-between align-items-center">
                        <h5 class="mb-0">Status</h5>
                        <button id="refresh-status-btn" class="btn btn-sm btn-outline-secondary">
                            <span class="spinner-border spinner-border-sm spinner" role="status" aria-hidden="true"></span>
                            Refresh
                        </button>
                    </div>
                    <div class="card-body">
                        <div class="row mb-3">
                            <div class="col-md-4">
                                <strong>Status:</strong>
                                <span id="scrape-status" class="badge bg-secondary">Idle</span>
                            </div>
                            <div class="col-md-4">
                                <strong>Last Scrape:</strong>
                                <span id="last-scrape">Never</span>
                            </div>
                            <div class="col-md-4">
                                <strong>Total Jobs:</strong>
                                <span id="total-jobs">0</span>
                            </div>
                        </div>
                        <div class="d-flex">
                            <button id="start-scrape-btn" class="btn btn-success me-2">Start Scraping</button>
                            <button id="stop-scrape-btn" class="btn btn-danger" disabled>Stop Scraping</button>
                        </div>
                    </div>
                </div>
            </div>

            <!-- Recent Jobs Panel -->
            <div class="col-md-6">
                <div class="card">
                    <div class="card-header">
                        <h5 class="mb-0">Recent Jobs</h5>
                    </div>
                    <div class="card-body">
                        <div class="table-responsive">
                            <table class="table table-striped" id="recent-jobs-table">
                                <thead>
                                    <tr>
                                        <th>Title</th>
                                        <th>Company</th>
                                        <th>Location</th>
                                        <th>Date</th>
                                    </tr>
                                </thead>
                                <tbody>
                                    <tr>
                                        <td colspan="4" class="text-center">No jobs found</td>
                                    </tr>
                                </tbody>
                            </table>
                        </div>
                    </div>
                </div>
            </div>
        </div>

        <div class="row">
            <!-- Configuration Panel -->
            <div class="col-md-6">
                <div class="card" id="config-card">
                    <div class="card-header d-flex justify-content-between align-items-center">
                        <h5 class="mb-0">Configuration</h5>
                        <button id="refresh-config-btn" class="btn btn-sm btn-outline-secondary">
                            <span class="spinner-border spinner-border-sm spinner" role="status" aria-hidden="true"></span>
                            Refresh
                        </button>
                    </div>
                    <div class="card-body">
                        <form id="config-form">
                            <!-- Form fields will be added dynamically -->
                        </form>
                    </div>
                </div>
            </div>

            <!-- Logs Panel -->
            <div class="col-md-6">
                <div class="card" id="logs-card">
                    <div class="card-header d-flex justify-content-between align-items-center">
                        <h5 class="mb-0">Logs</h5>
                        <button id="refresh-logs-btn" class="btn btn-sm btn-outline-secondary">
                            <span class="spinner-border spinner-border-sm spinner" role="status" aria-hidden="true"></span>
                            Refresh
                        </button>
                    </div>
                    <div class="card-body">
                        <div id="logs-container" class="log-viewer">
                            <!-- Logs will be added dynamically -->
                            <div class="text-center">No logs available</div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
    </div>

    <script src="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/js/bootstrap.bundle.min.js"></script>
    <script src="/static/admin/js/admin.js"></script>
</body>
</html>
EOF
fi

echo "Verifying setup..."
if [ -d "$ADMIN_DIR" ] && [ -d "$ADMIN_DIR/css" ] && [ -d "$ADMIN_DIR/js" ] && [ -f "$ADMIN_DIR/index.html" ]; then
    echo "Setup completed successfully!"
    echo "To start the admin dashboard, run: cd $ROOT_DIR && python3 src/main.py"
else
    echo "Error: Setup failed to complete properly."
    exit 1
fi 