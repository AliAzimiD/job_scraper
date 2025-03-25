/**
 * Job Scraper Web Application
 * Main JavaScript File
 */

// Wait for the DOM to be fully loaded
document.addEventListener('DOMContentLoaded', function () {
    // Initialize tooltips if Bootstrap is available
    if (typeof bootstrap !== 'undefined') {
        var tooltipTriggerList = [].slice.call(document.querySelectorAll('[data-bs-toggle="tooltip"]'));
        tooltipTriggerList.map(function (tooltipTriggerEl) {
            return new bootstrap.Tooltip(tooltipTriggerEl);
        });
    }

    // Auto-fade flash messages after 5 seconds
    const flashMessages = document.querySelectorAll('.alert.alert-dismissible');
    if (flashMessages.length > 0) {
        setTimeout(function () {
            flashMessages.forEach(function (message) {
                // Create fade-out effect
                message.style.transition = 'opacity 1s ease';
                message.style.opacity = '0';

                // Remove from DOM after animation completes
                setTimeout(function () {
                    message.remove();
                }, 1000);
            });
        }, 5000);
    }

    // Add animation to cards
    const cards = document.querySelectorAll('.card');
    cards.forEach(function (card, index) {
        card.style.opacity = '0';
        card.style.transform = 'translateY(20px)';

        setTimeout(function () {
            card.style.transition = 'opacity 0.5s ease, transform 0.5s ease';
            card.style.opacity = '1';
            card.style.transform = 'translateY(0)';
        }, 100 * index);
    });

    // Check for health status updates
    setupStatusRefresh();

    // Setup search form
    setupSearch();
});

/**
 * Setup auto-refresh for status information
 */
function setupStatusRefresh() {
    // Only run on status page
    if (!window.location.pathname.includes('/status')) return;

    // Refresh status every 60 seconds
    setInterval(function () {
        fetch('/api/status')
            .then(response => response.json())
            .then(data => {
                // Update status indicators
                updateStatusIndicators(data);

                // Update last refreshed time
                const refreshElement = document.getElementById('last-refreshed');
                if (refreshElement) {
                    const now = new Date();
                    refreshElement.textContent = now.toLocaleTimeString();
                }
            })
            .catch(error => {
                console.error('Error fetching status updates:', error);
            });
    }, 60000);
}

/**
 * Update status indicators based on API response
 */
function updateStatusIndicators(data) {
    // Example function to update UI elements with new status data
    if (!data) return;

    // Update components status
    for (const [component, status] of Object.entries(data.components || {})) {
        const statusElement = document.getElementById(`status-${component}`);
        if (statusElement) {
            // Update status class
            statusElement.className = '';
            statusElement.classList.add('badge');

            if (status === 'online') {
                statusElement.classList.add('bg-success');
                statusElement.textContent = 'Online';
            } else if (status === 'warning') {
                statusElement.classList.add('bg-warning');
                statusElement.textContent = 'Warning';
            } else if (status === 'offline') {
                statusElement.classList.add('bg-danger');
                statusElement.textContent = 'Offline';
            } else {
                statusElement.classList.add('bg-secondary');
                statusElement.textContent = 'Unknown';
            }
        }
    }
}

/**
 * Setup search functionality
 */
function setupSearch() {
    const searchForm = document.querySelector('.search-form');
    if (!searchForm) return;

    // Show advanced search options
    const advancedToggle = document.getElementById('advanced-search-toggle');
    if (advancedToggle) {
        const advancedOptions = document.getElementById('advanced-search-options');

        advancedToggle.addEventListener('click', function (e) {
            e.preventDefault();

            if (advancedOptions.style.display === 'none' || !advancedOptions.style.display) {
                advancedOptions.style.display = 'block';
                advancedToggle.textContent = 'Hide Advanced Options';
            } else {
                advancedOptions.style.display = 'none';
                advancedToggle.textContent = 'Show Advanced Options';
            }
        });
    }
}

/**
 * Format a date in a readable format
 */
function formatDate(dateString) {
    const date = new Date(dateString);
    return date.toLocaleDateString() + ' ' + date.toLocaleTimeString();
}

/**
 * Format a number with thousand separators
 */
function formatNumber(num) {
    return num.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ",");
} 