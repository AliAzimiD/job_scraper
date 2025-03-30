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

section "Git Authentication Setup"
echo "This script will help you set up Git authentication for the job_scraper repository."
echo "It will configure your Git identity and credential storage."

# Check if we're in a Git repository
if [ ! -d ".git" ]; then
    error "Not in a Git repository. Please run this script from the root of the Git repository."
    exit 1
fi

# Show current remote URL
echo "Current repository remote URL:"
git remote get-url origin 2>/dev/null || echo "No remote URL configured"

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

# Ask for user identity if not configured
read -p "Enter your Git username [leave empty to keep current]: " git_username
read -p "Enter your Git email [leave empty to keep current]: " git_email

if [ -n "$git_username" ]; then
    git config user.name "$git_username"
    success "Git username configured: $git_username"
elif [ -z "$current_name" ]; then
    warning "Git username not configured. Some Git operations may fail."
else
    success "Keeping current Git username: $current_name"
fi

if [ -n "$git_email" ]; then
    git config user.email "$git_email"
    success "Git email configured: $git_email"
elif [ -z "$current_email" ]; then
    warning "Git email not configured. Some Git operations may fail."
else
    success "Keeping current Git email: $current_email"
fi

# Configure credential storage
section "Configuring Git Credential Storage"

# Determine best credential helper based on platform
credential_helper=""
if command -v git-credential-store >/dev/null 2>&1; then
    credential_helper="store"
elif command -v git-credential-cache >/dev/null 2>&1; then
    credential_helper="cache --timeout=3600"  # Cache for 1 hour
fi

current_helper=$(git config --get credential.helper || echo "")
echo "Current credential helper: ${current_helper:-"None"}"

if [ -n "$credential_helper" ]; then
    read -p "Configure Git credential helper to '$credential_helper'? [Y/n]: " configure_helper
    if [[ "$configure_helper" != "n" && "$configure_helper" != "N" ]]; then
        git config credential.helper "$credential_helper"
        success "Git credential helper configured to $credential_helper"
    fi
else
    warning "No suitable credential helper found. You may need to enter credentials each time."
fi

# Configure remote URL (HTTPS vs SSH)
section "Remote URL Configuration"

current_url=$(git remote get-url origin 2>/dev/null || echo "")
echo "Current remote URL: ${current_url:-"None"}"

if [[ "$current_url" == https://* ]]; then
    echo "You are currently using HTTPS for Git operations."
    
    # Option to switch to SSH
    read -p "Would you like to switch to SSH for authentication? [y/N]: " switch_to_ssh
    if [[ "$switch_to_ssh" == "y" || "$switch_to_ssh" == "Y" ]]; then
        # Extract repository path from HTTPS URL and create SSH URL
        repo_path=$(echo "$current_url" | sed -E 's|https://github.com/(.+)$|\1|')
        ssh_url="git@github.com:$repo_path"
        
        # Update remote URL
        git remote set-url origin "$ssh_url"
        success "Remote URL updated to SSH: $ssh_url"
        
        # Instructions for SSH key setup
        echo ""
        echo "To use SSH authentication, you need to set up an SSH key:"
        echo "1. Generate SSH key pair: ssh-keygen -t ed25519 -C \"your_email@example.com\""
        echo "2. Start SSH agent: eval \"\$(ssh-agent -s)\""
        echo "3. Add your SSH key: ssh-add ~/.ssh/id_ed25519"
        echo "4. Copy public key: cat ~/.ssh/id_ed25519.pub"
        echo "5. Add the key to your GitHub account at: https://github.com/settings/keys"
    fi
elif [[ "$current_url" == git@* ]]; then
    echo "You are currently using SSH for Git operations."
    
    # Check if SSH key exists
    if [ ! -f ~/.ssh/id_ed25519 ] && [ ! -f ~/.ssh/id_rsa ]; then
        warning "No SSH key found. You may need to generate one."
        echo "To generate SSH key: ssh-keygen -t ed25519 -C \"your_email@example.com\""
    else
        success "SSH key found. Make sure it's added to your GitHub account."
    fi
else
    warning "Unrecognized remote URL format: $current_url"
fi

# Personal access token setup for HTTPS
if [[ "$current_url" == https://* ]] && [[ "$switch_to_ssh" != "y" && "$switch_to_ssh" != "Y" ]]; then
    section "Personal Access Token"
    
    echo "If you're using HTTPS, you'll need a Personal Access Token (PAT) for authentication."
    echo "GitHub no longer accepts password authentication for Git operations."
    
    echo ""
    echo "To create a Personal Access Token:"
    echo "1. Go to: https://github.com/settings/tokens"
    echo "2. Click 'Generate new token'"
    echo "3. Select the 'repo' scope"
    echo "4. Generate and copy the token"
    
    read -p "Have you created a Personal Access Token? [y/N]: " has_token
    if [[ "$has_token" == "y" || "$has_token" == "Y" ]]; then
        read -p "Would you like to store it in the credential helper? [y/N]: " store_token
        if [[ "$store_token" == "y" || "$store_token" == "Y" ]]; then
            # Extract username from URL if possible
            default_username=""
            if [[ "$current_url" =~ github.com/([^/]+) ]]; then
                default_username="${BASH_REMATCH[1]}"
            fi
            
            read -p "Enter your GitHub username [$default_username]: " github_username
            github_username=${github_username:-$default_username}
            
            read -s -p "Enter your Personal Access Token: " github_token
            echo ""
            
            if [ -n "$github_username" ] && [ -n "$github_token" ]; then
                # Use git credential approve to store credentials
                echo "url=https://github.com
username=$github_username
password=$github_token
" | git credential approve
                
                success "Personal Access Token stored in Git credential helper"
            else
                warning "Username or token is empty. Nothing stored."
            fi
        fi
    else
        warning "You'll need a Personal Access Token for HTTPS authentication with GitHub."
    fi
fi

# Test Git authentication
section "Testing Git Authentication"

echo "Testing Git authentication..."
if git fetch -q origin 2>/dev/null; then
    success "Git authentication successful! You can now perform Git operations."
else
    warning "Git authentication test failed. You may need to enter credentials manually on your next Git operation."
fi

section "Git Authentication Setup Complete"
echo "Your Git authentication has been configured."
echo "If you continue to have issues, please check the GitHub documentation:"
echo "https://docs.github.com/en/authentication" 