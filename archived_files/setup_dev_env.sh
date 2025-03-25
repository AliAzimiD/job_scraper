#!/bin/bash

# Create and activate virtual environment
python -m venv .venv
source .venv/bin/activate

# Install required packages for development
pip install -r requirements.txt

echo "Virtual environment created and dependencies installed."
echo "To activate the environment, run: source .venv/bin/activate" 