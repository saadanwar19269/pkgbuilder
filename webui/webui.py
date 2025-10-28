#!/usr/bin/env python3
import os
import sqlite3
from flask import Flask, render_template, jsonify

app = Flask(__name__)

def get_pkgbuilder_dir():
    return os.path.expanduser("~/.local/pkgbuilder")

@app.route('/')
def index():
    return render_template('index.html')

@app.route('/api/packages')
def list_packages():
    db_path = os.path.join(get_pkgbuilder_dir(), "db/build_cache.db")
    if not os.path.exists(db_path):
        return jsonify([])
    
    conn = sqlite3.connect(db_path)
    c = conn.cursor()
    
    packages = []
    for row in c.execute('SELECT pkgname, timestamp FROM build_cache ORDER BY timestamp DESC'):
        packages.append({
            'name': row[0],
            'last_built': row[1]
        })
    
    conn.close()
    return jsonify(packages)

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5000, debug=False)
