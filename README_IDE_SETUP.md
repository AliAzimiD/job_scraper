# IDE Setup Guide

## PyCharm Setup

1. Open the project in PyCharm
2. Go to File > Settings > Project: job_scraper_db > Project Structure
3. Find the `src` directory, right-click and select "Mark Directory as > Sources Root"
4. Apply and close

## VSCode Setup

1. Install the Python extension
2. Use the `.vscode/settings.json` file already added to the project
3. Reload the window with `Ctrl+Shift+P` > "Reload Window"

## Running in Docker (recommended)

The error "Import flask could not be resolved" is only an IDE/editor issue. The application still works correctly in Docker with:

```bash
./test_locally_offline.sh
```

The docker container has all dependencies installed and configured properly. 