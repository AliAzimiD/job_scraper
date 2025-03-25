/**
 * Main JavaScript file for the Job Scraper application
 */

document.addEventListener('DOMContentLoaded', function () {
    console.log('Job Scraper application initialized');

    // Initialize all components that should run on page load
    setupStatusRefresh();
    setupSearch();

    // Initialize tooltips and popovers if Bootstrap is available
    if (typeof bootstrap !== 'undefined') {
        var tooltipTriggerList = [].slice.call(document.querySelectorAll('[data-bs-toggle="tooltip"]'));
        tooltipTriggerList.map(function (tooltipTriggerEl) {
            return new bootstrap.Tooltip(tooltipTriggerEl);
        });

        var popoverTriggerList = [].slice.call(document.querySelectorAll('[data-bs-toggle="popover"]'));
        popoverTriggerList.map(function (popoverTriggerEl) {
            return new bootstrap.Popover(popoverTriggerEl);
        });
    }
});

/**
 * Sets up automatic refresh of status indicators
 */
function setupStatusRefresh() {
    // Only run on pages that have status indicators
    const statusIndicators = document.querySelectorAll('.status-indicator');
    if (statusIndicators.length === 0) return;

    // Check for scraper status every 5 seconds
    setInterval(function () {
        fetch('/api/scraper-status')
            .then(response => response.json())
            .then(data => {
                updateStatusIndicators(data);
            })
            .catch(error => {
                console.error('Error fetching status:', error);
            });
    }, 5000);

    // Initial status update
    fetch('/api/scraper-status')
        .then(response => response.json())
        .then(data => {
            updateStatusIndicators(data);
        })
        .catch(error => {
            console.error('Error fetching status:', error);
        });
}

/**
 * Updates all status indicators based on the provided data
 * @param {Object} data - Status data from the API
 */
function updateStatusIndicators(data) {
    // Update system status indicator
    const systemStatusIndicator = document.querySelector('.system-status');
    if (systemStatusIndicator) {
        systemStatusIndicator.className = 'status-indicator';
        systemStatusIndicator.classList.add('status-online');
    }

    // Update scraper status
    const scraperStatus = document.getElementById('scraper-status');
    if (scraperStatus) {
        if (data.running) {
            scraperStatus.textContent = 'Running';
            scraperStatus.classList.remove('text-danger', 'text-warning', 'text-muted');
            scraperStatus.classList.add('text-primary');
        } else if (data.status === 'error') {
            scraperStatus.textContent = 'Error';
            scraperStatus.classList.remove('text-primary', 'text-warning', 'text-muted');
            scraperStatus.classList.add('text-danger');
        } else if (data.status === 'completed') {
            scraperStatus.textContent = 'Completed';
            scraperStatus.classList.remove('text-primary', 'text-danger', 'text-muted');
            scraperStatus.classList.add('text-success');
        } else {
            scraperStatus.textContent = 'Idle';
            scraperStatus.classList.remove('text-primary', 'text-danger', 'text-success');
            scraperStatus.classList.add('text-muted');
        }
    }
}

/**
 * Sets up search functionality
 */
function setupSearch() {
    const searchForm = document.getElementById('search-form');
    if (!searchForm) return;

    searchForm.addEventListener('submit', function (event) {
        event.preventDefault();

        const keyword = document.getElementById('search-keyword').value;
        const location = document.getElementById('search-location').value;
        const company = document.getElementById('search-company').value;

        // Build query string
        let queryString = '?';
        if (keyword) queryString += `keyword=${encodeURIComponent(keyword)}&`;
        if (location) queryString += `location=${encodeURIComponent(location)}&`;
        if (company) queryString += `company=${encodeURIComponent(company)}&`;

        // Remove trailing & if present
        if (queryString.endsWith('&')) {
            queryString = queryString.slice(0, -1);
        }

        // Redirect to search results page
        window.location.href = '/search' + queryString;
    });
}

/**
 * Formats a date string to a human-readable format
 * @param {string} dateString - ISO date string
 * @returns {string} Formatted date string
 */
function formatDate(dateString) {
    if (!dateString) return '';
    const date = new Date(dateString);
    return date.toLocaleDateString() + ' ' + date.toLocaleTimeString();
}

/**
 * Formats a number with thousands separators
 * @param {number} num - Number to format
 * @returns {string} Formatted number string
 */
function formatNumber(num) {
    return num.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
} 