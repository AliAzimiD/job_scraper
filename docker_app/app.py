from flask import Flask
import os

app = Flask(__name__)

@app.route(\"/\")
def hello():
    return \"<h1>Job Scraper Application</h1><p>Successfully deployed with Docker!</p>\"

if __name__ == \"__main__\":
    port = int(os.environ.get(\"PORT\", 5000))
    app.run(host=\"0.0.0.0\", port=port)
