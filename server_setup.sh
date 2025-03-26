#!/bin/bash
# This is a generated script to prepare the server for deployment

# Check if Docker is installed
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    usermod -aG docker "$USER"
    systemctl enable docker
    systemctl start docker
    rm get-docker.sh
fi

# Set up GitHub SSH access if needed
if [ ! -f ~/.ssh/id_ed25519 ]; then
    echo "Setting up SSH key for GitHub access..."
    mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    
    # Generate SSH key non-interactively
    ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "server-deploy-key"
    
    # Display the public key for the user to add to GitHub
    echo "-------------------------------------------------------------------------"
    echo "IMPORTANT: Add this SSH key to your GitHub account at https://github.com/settings/keys"
    echo "-------------------------------------------------------------------------"
    cat ~/.ssh/id_ed25519.pub
    echo "-------------------------------------------------------------------------"
    echo "After adding the key to GitHub, the deployment will continue."
    echo "You have 60 seconds to add this key to GitHub..."
    sleep 60
    
    # Configure SSH to use this key for GitHub
    cat > ~/.ssh/config << 'SSHCONFIG'
Host github.com
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
SSHCONFIG
    
    chmod 600 ~/.ssh/config
    
    # Test the GitHub connection
    echo "Testing GitHub SSH connection..."
    ssh -o StrictHostKeyChecking=no -T git@github.com || echo "GitHub connection test completed."
fi

# Create deployment directory if it doesn't exist
mkdir -p "$REMOTE_PATH"

echo "Server preparation completed"
