from flask import Flask; app = Flask(__name__); @app.route('/'); def hello(): return '<h1>Test App</h1>'; def create_app(): return app
