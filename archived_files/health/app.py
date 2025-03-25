from flask import Flask, jsonify
import psutil
import os
import time
import socket
import subprocess

app = Flask(__name__)
start_time = time.time()

@app.route("/health")
def health():
    uptime = time.time() - start_time
    log_dir = "/app/job_data/logs"
    log_files = [f for f in os.listdir(log_dir) if f.endswith(".log")]
    latest_log = None
    if log_files:
        latest_log = max([os.path.join(log_dir, f) for f in log_files], key=os.path.getmtime)
    
    # Check database connectivity
    db_status = "unknown"
    try:
        if os.environ.get("POSTGRES_HOST"):
            result = subprocess.run(
                ["pg_isready", "-h", os.environ.get("POSTGRES_HOST"), "-U", os.environ.get("POSTGRES_USER")],
                capture_output=True,
                text=True,
                timeout=5
            )
            db_status = "connected" if result.returncode == 0 else "disconnected"
    except Exception as e:
        db_status = f"error: {str(e)}"
    
    # Check if cron is running
    cron_status = "unknown"
    try:
        result = subprocess.run(["pgrep", "cron"], capture_output=True)
        cron_status = "running" if result.returncode == 0 else "not running"
    except Exception:
        pass
    
    return jsonify({
        "status": "healthy",
        "uptime_seconds": uptime,
        "memory_usage_percent": psutil.virtual_memory().percent,
        "cpu_usage_percent": psutil.cpu_percent(interval=1),
        "disk_usage_percent": psutil.disk_usage("/").percent,
        "latest_log": latest_log,
        "environment": os.environ.get("SCRAPER_ENV", "unknown"),
        "hostname": socket.gethostname(),
        "database": db_status,
        "cron": cron_status
    })

@app.route("/metrics")
def metrics():
    # More detailed metrics for monitoring systems
    memory = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    
    return jsonify({
        "memory": {
            "total": memory.total,
            "available": memory.available,
            "percent": memory.percent,
            "used": memory.used,
            "free": memory.free
        },
        "cpu": {
            "percent": psutil.cpu_percent(interval=1),
            "count": psutil.cpu_count()
        },
        "disk": {
            "total": disk.total,
            "used": disk.used,
            "free": disk.free,
            "percent": disk.percent
        },
        "process": {
            "open_files": len(psutil.Process().open_files()),
            "connections": len(psutil.Process().connections()),
            "threads": psutil.Process().num_threads()
        }
    })

if __name__ == "__main__":
    port = int(os.environ.get("HEALTH_PORT", 8081))
    app.run(host="0.0.0.0", port=port) 