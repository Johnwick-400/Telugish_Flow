"""Loopback account service for Telugish Flow."""

import hashlib
import os
import re
import secrets
import threading
import time
from collections import deque
from datetime import datetime, timedelta, timezone

from flask import Flask, jsonify, request
from pymongo import ASCENDING, MongoClient
from pymongo.errors import DuplicateKeyError, PyMongoError
from werkzeug.security import check_password_hash, generate_password_hash

EMAIL = re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+")
HASH_METHOD = "scrypt:32768:8:3"
DUMMY_HASH = generate_password_hash(secrets.token_urlsafe(32), method=HASH_METHOD)
SESSION_DAYS = 7


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def create_app(db):
    app = Flask(__name__)
    app.config["MAX_CONTENT_LENGTH"] = 4096
    accounts = db["accounts"]
    sessions = db["sessions"]
    accounts.create_index([("email", ASCENDING)], unique=True)
    sessions.create_index([("expires", ASCENDING)], expireAfterSeconds=0)
    attempts = deque()
    limit_lock = threading.Lock()
    hash_slots = threading.BoundedSemaphore(2)

    @app.before_request
    def loopback_only():
        if request.host not in {"127.0.0.1:8766", "localhost:8766"}:
            return jsonify(error="Invalid service host."), 400

    @app.errorhandler(PyMongoError)
    def database_error(_):
        return jsonify(error="The account database is unavailable."), 503

    def allow_attempt():
        now = time.monotonic()
        with limit_lock:
            while attempts and attempts[0] <= now - 60:
                attempts.popleft()
            if len(attempts) >= 12:
                return False
            attempts.append(now)
            return True

    def issue_session(email, status=200):
        token = secrets.token_urlsafe(32)
        expires = datetime.now(timezone.utc) + timedelta(days=SESSION_DAYS)
        sessions.insert_one({"_id": token_hash(token), "email": email, "expires": expires})
        response = jsonify(email=email, token=token)
        response.headers["Cache-Control"] = "no-store"
        return response, status

    def credentials():
        data = request.get_json(silent=True)
        if not isinstance(data, dict):
            return None, None
        email, password = data.get("email"), data.get("password")
        if not isinstance(email, str) or not isinstance(password, str):
            return None, None
        email = email.strip().lower()
        try:
            password_size = len(password.encode())
        except UnicodeError:
            return None, None
        if len(email) > 254 or not EMAIL.fullmatch(email) or not 1 <= password_size <= 128:
            return None, None
        return email, password

    @app.get("/health")
    def health():
        db.command("ping")
        return jsonify(status="ok")

    @app.post("/signup")
    def signup():
        email, password = credentials()
        if not email or len(password) < 12:
            return jsonify(error="Use a valid email and a password of at least 12 characters."), 400
        if not allow_attempt() or not hash_slots.acquire(blocking=False):
            return jsonify(error="Too many attempts. Try again shortly."), 429
        try:
            hashed = generate_password_hash(password, method=HASH_METHOD)
            accounts.insert_one({"email": email, "password_hash": hashed,
                                 "created": datetime.now(timezone.utc)})
        except DuplicateKeyError:
            return jsonify(error="Could not create account. Try signing in."), 409
        finally:
            hash_slots.release()
        return issue_session(email, 201)

    @app.post("/signin")
    def signin():
        email, password = credentials()
        if not email:
            return jsonify(error="Enter a valid email and password."), 400
        if not allow_attempt() or not hash_slots.acquire(blocking=False):
            return jsonify(error="Too many attempts. Try again shortly."), 429
        try:
            account = accounts.find_one({"email": email}, {"password_hash": 1})
            matches = check_password_hash(account["password_hash"] if account else DUMMY_HASH, password)
        finally:
            hash_slots.release()
        if not account or not matches:
            return jsonify(error="Email or password is incorrect."), 401
        return issue_session(email)

    @app.post("/signout")
    def signout():
        prefix, _, token = request.headers.get("Authorization", "").partition(" ")
        if prefix.lower() == "bearer" and re.fullmatch(r"[A-Za-z0-9_-]{43}", token):
            sessions.delete_one({"_id": token_hash(token)})
        return jsonify(status="ok")

    return app


if __name__ == "__main__":
    from getpass import getpass

    uri = os.environ.get("TELUGISH_MONGODB_URI") or getpass("MongoDB URI: ").strip()
    try:
        client = MongoClient(uri, serverSelectionTimeoutMS=7000, connectTimeoutMS=5000)
        client.admin.command("ping")
        service = create_app(client["telugish_flow"])
    except (PyMongoError, ValueError):
        raise SystemExit("MongoDB connection or account indexes unavailable. Check Atlas network access and database permissions.")
    service.run(host="127.0.0.1", port=8766, debug=False, use_reloader=False)
