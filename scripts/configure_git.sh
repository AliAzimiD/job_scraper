#!/bin/bash
set -e

# Get script directory for proper path resolution
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "${PROJECT_ROOT}"  # Ensure we're in the project root

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'  # No Color

# Print a section header
section() {
    echo -e "\n${BLUE}=== $1 ===${NC}\n"
}

# Print a success message
success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Print an error message
error() {
    echo -e "${RED}✗ $1${NC}"
}

# Print a warning message
warning() {
    echo -e "${YELLOW}! $1${NC}"
}

# Display usage information
usage() {
    echo "Usage: $0 [options]"
    echo
    echo "This script configures Git authentication for the job_scraper repository."
    echo
    echo "Options:"
    echo "  --name NAME           Set Git user.name"
    echo "  --email EMAIL         Set Git user.email"
    echo "  --store-credentials   Use the store credential helper"
    echo "  --cache-credentials   Use the cache credential helper"
    echo "  --token TOKEN         Set GitHub personal access token"
    echo "  --use-ssh             Convert HTTPS remote to SSH"
    echo "  --github-user USER    GitHub username (used with --token)"
    echo "  --help                Display this help message"
    echo
    echo "Environment variables:"
    echo "  GIT_USER_NAME           Alternative to --name"
    echo "  GIT_USER_EMAIL          Alternative to --email"
    echo "  GIT_CREDENTIAL_HELPER   'store' or 'cache'"
    echo "  GITHUB_TOKEN            Alternative to --token"
    echo "  GITHUB_USER             Alternative to --github-user"
    echo "  GIT_USE_SSH             Set to 'true' to use SSH"
    echo
    echo "Example:"
    echo "  $0 --name 'John Doe' --email 'john@example.com' --store-credentials"
    echo "  $0 --use-ssh"
    echo
    echo "Or using environment variables:"
    echo "  GIT_USER_NAME='John Doe' GIT_USER_EMAIL='john@example.com' GIT_CREDENTIAL_HELPER='store' $0"
    exit 1
}

# Parse command line arguments
while [ "$#" -gt 0 ]; do
    case "$1" in
        --name)
            GIT_USER_NAME="$2"
            shift 2
            ;;
        --email)
            GIT_USER_EMAIL="$2"
            shift 2
            ;;
        --store-credentials)
            GIT_CREDENTIAL_HELPER="store"
            shift
            ;;
        --cache-credentials)
            GIT_CREDENTIAL_HELPER="cache"
            shift
            ;;
        --token)
            GITHUB_TOKEN="$2"
            shift 2
            ;;
        --use-ssh)
            GIT_USE_SSH="true"
            shift
            ;;
        --github-user)
            GITHUB_USER="$2"
            shift 2
            ;;
        --help)
            usage
            ;;
        *)
            error "Unknown option: $1"
            usage
            ;;
    esac
done

section "Git Authentication Configuration"
echo "Non-interactive Git authentication setup"

# Check if we're in a Git repository
if [ ! -d ".git" ]; then
    error "Not in a Git repository. Please run this script from the root of the Git repository."
    exit 1
fi

# Show current remote URL
current_url=$(git remote get-url origin 2>/dev/null || echo "")
echo "Current repository remote URL: ${current_url:-"None"}"

# Configure user identity
section "Configuring Git Identity"

# Check current configuration
current_name=$(git config --get user.name || echo "")
current_email=$(git config --get user.email || echo "")

echo "Current Git identity:"
if [ -n "$current_name" ] && [ -n "$current_email" ]; then
    echo "Name: $current_name"
    echo "Email: $current_email"
else
    echo "Git identity not fully configured."
fi

# Set user.name if provided
if [ -n "$GIT_USER_NAME" ]; then
    git config user.name "$GIT_USER_NAME"
    success "Git username configured: $GIT_USER_NAME"
elif [ -z "$current_name" ]; then
    warning "Git username not configured. Set it with --name or GIT_USER_NAME."
else
    success "Keeping current Git username: $current_name"
fi

# Set user.email if provided
if [ -n "$GIT_USER_EMAIL" ]; then
    git config user.email "$GIT_USER_EMAIL"
    success "Git email configured: $GIT_USER_EMAIL"
elif [ -z "$current_email" ]; then
    warning "Git email not configured. Set it with --email or GIT_USER_EMAIL."
else
    success "Keeping current Git email: $current_email"
fi

# Configure credential storage
section "Configuring Git Credential Storage"

current_helper=$(git config --get credential.helper || echo "")
echo "Current credential helper: ${current_helper:-"None"}"

if [ -n "$GIT_CREDENTIAL_HELPER" ]; then
    if [ "$GIT_CREDENTIAL_HELPER" = "store" ]; then
        if command -v git-credential-store >/dev/null 2>&1; then
            git config credential.helper store
            success "Git credential helper configured to store"
        else
            warning "git-credential-store not available. Credentials won't be stored."
        fi
    elif [ "$GIT_CREDENTIAL_HELPER" = "cache" ]; then
        if command -v git-credential-cache >/dev/null 2>&1; then
            git config credential.helper "cache --timeout=3600"  # Cache for 1 hour
            success "Git credential helper configured to cache (1 hour timeout)"
        else
            warning "git-credential-cache not available. Credentials won't be cached."
        fi
    else
        warning "Unknown credential helper: $GIT_CREDENTIAL_HELPER"
    fi
fi

# Configure remote URL (HTTPS vs SSH)
section "Remote URL Configuration"

if [ "$GIT_USE_SSH" = "true" ] && [[ "$current_url" == https://* ]]; then
    echo "Converting HTTPS URL to SSH..."
    
    # Extract repository path from HTTPS URL and create SSH URL
    repo_path=$(echo "$current_url" | sed -E 's|https://github.com/(.+)$|\1|')
    ssh_url="git@github.com:$repo_path"
    
    # Update remote URL
    git remote set-url origin "$ssh_url"
    success "Remote URL updated to SSH: $ssh_url"
    
    echo "SSH key requirements:"
    echo "- You need a valid SSH key in ~/.ssh/"
    echo "- The public key must be added to your GitHub account"
    echo "- Run 'ssh -T git@github.com' to test your SSH connection"
fi

# Store GitHub token if provided
if [ -n "$GITHUB_TOKEN" ] && [ -n "$GIT_CREDENTIAL_HELPER" ]; then
    section "Storing GitHub Token"
    
    # Default to the username from the URL if not provided
    if [ -z "$GITHUB_USER" ] && [[ "$current_url" =~ github.com/([^/]+) ]]; then
        GITHUB_USER="${BASH_REMATCH[1]}"
    fi
    
    if [ -n "$GITHUB_USER" ]; then
        # Use git credential approve to store credentials
        echo "url=https://github.com
username=$GITHUB_USER
password=$GITHUB_TOKEN
" | git credential approve
        
        success "GitHub token stored in Git credential helper for user $GITHUB_USER"
    else
        warning "GitHub username not provided. Token not stored."
        echo "Use --github-user or GITHUB_USER to specify your GitHub username."
    fi
fi

# Test Git authentication
section "Testing Git Authentication"

echo "Testing Git authentication..."
if git fetch -q origin 2>/dev/null; then
    success "Git authentication successful! You can now perform Git operations."
else
    warning "Git authentication test failed."
    echo "Possible reasons:"
    echo "- Incorrect credentials"
    echo "- SSH key not set up properly"
    echo "- No internet connection"
    echo "- Repository access issues"
fi

section "Git Authentication Setup Complete" 