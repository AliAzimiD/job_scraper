#!/usr/bin/env python3
"""
Simple wrapper to run the web app on port 5001
"""
import os
from src.simple_web_app import app

if __name__ == '__main__':
    port = 5001
    host = '0.0.0.0'
    print(f"Starting web application on {host}:{port}")
    app.run(host=host, port=port)
