/**
 * Admin Dashboard JavaScript
 * Controls the functionality of the Job Scraper Admin Dashboard
 */

// API endpoints
const API_ENDPOINTS = {
    STATS: '/api/stats',
    LOGS: '/api/logs',
    CONFIG: '/api/config',
    SCRAPE_START: '/api/scrape/start',
    SCRAPE_STOP: '/api/scrape/stop'
};

// Global variables
let refreshInterval;
let isRefreshing = false;

// Initialize when DOM is loaded
document.addEventListener('DOMContentLoaded', () => {
    setupEventHandlers();
    refreshAll();
    
    // Auto refresh every 30 seconds
    refreshInterval = setInterval(refreshAll, 30000);
});

/**
 * Refresh the status panel with current stats
 */
async function refreshStatus() {
    if (isRefreshing) return;
    isRefreshing = true;
    
    const statusPanel = document.getElementById('status-panel');
    const jobCountElement = document.getElementById('job-count');
    const lastScrapeElement = document.getElementById('last-scrape');
    const statusBadgeElement = document.getElementById('status-badge');
    const jobTableBody = document.getElementById('recent-jobs-body');
    
    showLoading('status-panel');
    
    try {
        const response = await fetch(API_ENDPOINTS.STATS);
        
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        const data = await response.json();
        
        // Update job count
        if (jobCountElement) {
            jobCountElement.textContent = data.total_jobs || 0;
        }
        
        // Update last scrape time
        if (lastScrapeElement && data.last_scrape) {
            const scrapeDate = new Date(data.last_scrape);
            lastScrapeElement.textContent = scrapeDate.toLocaleString();
        } else if (lastScrapeElement) {
            lastScrapeElement.textContent = 'Never';
        }
        
        // Update status badge
        if (statusBadgeElement) {
            if (data.status === 'running') {
                statusBadgeElement.textContent = 'Running';
                statusBadgeElement.className = 'badge bg-success status-active';
                document.getElementById('start-scrape-btn').disabled = true;
                document.getElementById('stop-scrape-btn').disabled = false;
            } else {
                statusBadgeElement.textContent = 'Idle';
                statusBadgeElement.className = 'badge bg-secondary';
                document.getElementById('start-scrape-btn').disabled = false;
                document.getElementById('stop-scrape-btn').disabled = true;
            }
        }
        
        // Update recent jobs
        if (jobTableBody && data.recent_jobs && Array.isArray(data.recent_jobs)) {
            updateRecentJobs(data.recent_jobs);
        }
        
    } catch (error) {
        console.error('Error refreshing status:', error);
        showError('status-panel', 'Failed to load status data. See console for details.');
    } finally {
        isRefreshing = false;
    }
}

/**
 * Update the recent jobs table
 * @param {Array} jobs - Array of job objects
 */
function updateRecentJobs(jobs) {
    const jobTableBody = document.getElementById('recent-jobs-body');
    if (!jobTableBody) return;
    
    // Clear existing table
    jobTableBody.innerHTML = '';
    
    if (!jobs || jobs.length === 0) {
        const row = document.createElement('tr');
        row.innerHTML = '<td colspan="4" class="text-center">No jobs found</td>';
        jobTableBody.appendChild(row);
        return;
    }
    
    // Add each job to table
    jobs.forEach(job => {
        const row = document.createElement('tr');
        
        row.innerHTML = `
            <td>${job.title || 'N/A'}</td>
            <td>${job.company || 'N/A'}</td>
            <td>${job.location || 'N/A'}</td>
            <td>${job.date ? new Date(job.date).toLocaleDateString() : 'N/A'}</td>
        `;
        
        jobTableBody.appendChild(row);
    });
}

/**
 * Refresh the logs panel
 */
async function refreshLogs() {
    const logsContainer = document.getElementById('logs-container');
    const logLimitInput = document.getElementById('log-limit');
    
    if (!logsContainer) return;
    
    showLoading('logs-container');
    
    try {
        // Get the log limit from input or use default
        const limit = logLimitInput && !isNaN(logLimitInput.value) ? 
            parseInt(logLimitInput.value) : 100;
            
        const response = await fetch(`${API_ENDPOINTS.LOGS}?limit=${limit}`);
        
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        const data = await response.json();
        
        // Clear and update logs
        logsContainer.innerHTML = '';
        
        if (!data.logs || data.logs.length === 0) {
            logsContainer.innerHTML = '<p class="log-entry">No logs found</p>';
            return;
        }
        
        data.logs.forEach(log => {
            const logEntry = document.createElement('p');
            logEntry.className = 'log-entry';
            logEntry.textContent = log;
            logsContainer.appendChild(logEntry);
        });
        
        // Scroll to bottom of logs
        logsContainer.scrollTop = logsContainer.scrollHeight;
        
    } catch (error) {
        console.error('Error refreshing logs:', error);
        showError('logs-container', 'Failed to load logs. See console for details.');
    }
}

/**
 * Refresh the configuration panel
 */
async function refreshConfig() {
    const configForm = document.getElementById('config-form');
    
    if (!configForm) return;
    
    showLoading('config-form');
    
    try {
        const response = await fetch(API_ENDPOINTS.CONFIG);
        
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        const data = await response.json();
        
        // Clear form
        configForm.innerHTML = '';
        
        if (data.error) {
            showError('config-form', `Error loading configuration: ${data.error}`);
            return;
        }
        
        // Create form fields dynamically
        Object.entries(data).forEach(([key, value]) => {
            // Skip internal properties
            if (key.startsWith('_')) return;
            
            if (typeof value === 'object' && value !== null) {
                // Create fieldset for objects
                const fieldset = document.createElement('fieldset');
                fieldset.className = 'mb-3 p-3 border rounded';
                
                const legend = document.createElement('legend');
                legend.className = 'float-none w-auto px-2';
                legend.textContent = key;
                fieldset.appendChild(legend);
                
                // Recursively create fields for nested objects
                Object.entries(value).forEach(([nestedKey, nestedValue]) => {
                    createFormField(fieldset, `${key}.${nestedKey}`, nestedValue);
                });
                
                configForm.appendChild(fieldset);
            } else {
                // Create field for primitive values
                createFormField(configForm, key, value);
            }
        });
        
        // Add submit button
        const submitBtn = document.createElement('button');
        submitBtn.type = 'submit';
        submitBtn.className = 'btn btn-primary';
        submitBtn.textContent = 'Save Configuration';
        configForm.appendChild(submitBtn);
        
    } catch (error) {
        console.error('Error refreshing config:', error);
        showError('config-form', 'Failed to load configuration. See console for details.');
    }
}

/**
 * Create a form field for a config item
 * @param {HTMLElement} container - Container to add field to
 * @param {string} key - Config key
 * @param {any} value - Config value
 */
function createFormField(container, key, value) {
    const formGroup = document.createElement('div');
    formGroup.className = 'mb-3';
    
    const label = document.createElement('label');
    label.className = 'form-label';
    label.textContent = key;
    formGroup.appendChild(label);
    
    let input;
    
    // Create appropriate input based on value type
    if (typeof value === 'boolean') {
        // Checkbox for boolean
        input = document.createElement('div');
        input.className = 'form-check';
        
        const checkbox = document.createElement('input');
        checkbox.type = 'checkbox';
        checkbox.className = 'form-check-input';
        checkbox.id = key;
        checkbox.name = key;
        checkbox.checked = value;
        
        const checkLabel = document.createElement('label');
        checkLabel.className = 'form-check-label';
        checkLabel.htmlFor = key;
        checkLabel.textContent = 'Enabled';
        
        input.appendChild(checkbox);
        input.appendChild(checkLabel);
    } else if (typeof value === 'number') {
        // Number input
        input = document.createElement('input');
        input.type = 'number';
        input.className = 'form-control';
        input.id = key;
        input.name = key;
        input.value = value;
    } else {
        // Text input for everything else
        input = document.createElement('input');
        input.type = 'text';
        input.className = 'form-control';
        input.id = key;
        input.name = key;
        input.value = value || '';
    }
    
    formGroup.appendChild(input);
    container.appendChild(formGroup);
}

/**
 * Refresh all panels
 */
async function refreshAll() {
    await Promise.all([
        refreshStatus(),
        refreshLogs(),
        refreshConfig()
    ]);
}

/**
 * Show loading indicator in element
 * @param {string} elementId - ID of element to show loading in
 */
function showLoading(elementId) {
    const element = document.getElementById(elementId);
    if (element) {
        element.classList.add('loading');
    }
}

/**
 * Show error message in element
 * @param {string} elementId - ID of element to show error in
 * @param {string} message - Error message to display
 */
function showError(elementId, message) {
    const element = document.getElementById(elementId);
    if (element) {
        element.classList.remove('loading');
        element.innerHTML = `<div class="alert alert-danger">${message}</div>`;
    }
}

/**
 * Set up event handlers for buttons and forms
 */
function setupEventHandlers() {
    // Refresh buttons
    document.getElementById('refresh-status-btn')?.addEventListener('click', refreshStatus);
    document.getElementById('refresh-logs-btn')?.addEventListener('click', refreshLogs);
    document.getElementById('refresh-config-btn')?.addEventListener('click', refreshConfig);
    
    // Start/stop scrape buttons
    document.getElementById('start-scrape-btn')?.addEventListener('click', async () => {
        try {
            const response = await fetch(API_ENDPOINTS.SCRAPE_START, {
                method: 'POST'
            });
            
            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
            }
            
            const data = await response.json();
            
            if (data.success) {
                refreshStatus();
                refreshLogs();
            } else {
                alert(`Failed to start scrape: ${data.message || 'Unknown error'}`);
            }
        } catch (error) {
            console.error('Error starting scrape:', error);
            alert('Failed to start scrape. See console for details.');
        }
    });
    
    document.getElementById('stop-scrape-btn')?.addEventListener('click', async () => {
        try {
            const response = await fetch(API_ENDPOINTS.SCRAPE_STOP, {
                method: 'POST'
            });
            
            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
            }
            
            const data = await response.json();
            
            if (data.success) {
                refreshStatus();
                refreshLogs();
            } else {
                alert(`Failed to stop scrape: ${data.message || 'Unknown error'}`);
            }
        } catch (error) {
            console.error('Error stopping scrape:', error);
            alert('Failed to stop scrape. See console for details.');
        }
    });
    
    // Config form submission
    document.getElementById('config-form')?.addEventListener('submit', async (e) => {
        e.preventDefault();
        
        const form = e.target;
        const formData = new FormData(form);
        const config = {};
        
        // Build config object from form data
        for (const [key, value] of formData.entries()) {
            if (key.includes('.')) {
                // Handle nested objects
                const [parent, child] = key.split('.');
                if (!config[parent]) {
                    config[parent] = {};
                }
                
                // Convert value to appropriate type
                if (value === 'on') {
                    config[parent][child] = true;
                } else if (value === 'off') {
                    config[parent][child] = false;
                } else if (!isNaN(value) && value !== '') {
                    config[parent][child] = Number(value);
                } else {
                    config[parent][child] = value;
                }
            } else {
                // Handle top-level values
                if (value === 'on') {
                    config[key] = true;
                } else if (value === 'off') {
                    config[key] = false;
                } else if (!isNaN(value) && value !== '') {
                    config[key] = Number(value);
                } else {
                    config[key] = value;
                }
            }
        }
        
        try {
            const response = await fetch(API_ENDPOINTS.CONFIG, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify(config)
            });
            
            if (!response.ok) {
                throw new Error(`HTTP error! status: ${response.status}`);
            }
            
            const data = await response.json();
            
            if (data.success) {
                alert('Configuration saved successfully!');
                refreshConfig();
            } else {
                alert(`Failed to save configuration: ${data.error || 'Unknown error'}`);
            }
        } catch (error) {
            console.error('Error saving config:', error);
            alert('Failed to save configuration. See console for details.');
        }
    });
    
    // Log limit input change
    document.getElementById('log-limit')?.addEventListener('change', refreshLogs);
}

// Cleanup on page unload
window.addEventListener('beforeunload', () => {
    clearInterval(refreshInterval);
}); 