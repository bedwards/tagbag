#!/usr/bin/env python3
"""Threaded HTTP webhook receiver for TagBag Code Reviewer.

Replaces the netcat-based listener to handle concurrent webhook deliveries.
Writes accepted webhooks to the review queue file for the bash queue consumer.
"""
import hashlib
import hmac
import json
import os
import sys
import fcntl
from http.server import HTTPServer, BaseHTTPRequestHandler
from socketserver import ThreadingMixIn
from datetime import datetime

REVIEW_PORT = int(os.environ.get("TAGBAG_REVIEW_PORT", "9876"))
CONFIG_DIR = os.environ.get("TAGBAG_CONFIG_DIR", os.path.expanduser("~/.config/tagbag"))
REVIEW_QUEUE = os.path.join(CONFIG_DIR, "review-queue")
REVIEW_LOG = os.path.join(CONFIG_DIR, "reviewer.log")
WEBHOOK_SECRET = os.environ.get("GITEA_WEBHOOK_SECRET", "")
QUEUE_MAX = int(os.environ.get("TAGBAG_REVIEW_QUEUE_MAX", "50"))
QUEUE_WARN = int(os.environ.get("TAGBAG_REVIEW_QUEUE_WARN", "10"))
QUEUE_LOCK = REVIEW_QUEUE + ".lock"


def log(msg):
    line = f"[{datetime.now().strftime('%Y-%m-%dT%H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        with open(REVIEW_LOG, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def verify_signature(body: bytes, signature: str) -> bool:
    if not WEBHOOK_SECRET:
        log("WARNING: GITEA_WEBHOOK_SECRET not set - skipping signature verification")
        return True
    if not signature:
        log("REJECTED: missing X-Gitea-Signature header")
        return False
    expected = hmac.new(
        WEBHOOK_SECRET.encode(), body, hashlib.sha256
    ).hexdigest()
    if not hmac.compare_digest(expected, signature):
        log("REJECTED: invalid webhook signature")
        return False
    return True


def enqueue(repo: str, sha: str, ref: str):
    entry = f"{repo} {sha} {ref}\n"
    fd = os.open(QUEUE_LOCK, os.O_WRONLY | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        # Check queue depth
        try:
            with open(REVIEW_QUEUE) as f:
                lines = f.readlines()
        except FileNotFoundError:
            lines = []

        depth = len(lines)
        if depth >= QUEUE_MAX:
            log(f"WARNING: Queue full ({depth}/{QUEUE_MAX}) - dropping oldest entry")
            lines = lines[1:]
        elif depth >= QUEUE_WARN:
            log(f"WARNING: Queue depth {depth}/{QUEUE_MAX}")

        lines.append(entry)
        with open(REVIEW_QUEUE, "w") as f:
            f.writelines(lines)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)
        signature = self.headers.get("X-Gitea-Signature", "")

        if not verify_signature(body, signature):
            self.send_response(401)
            self.send_header("Content-Length", "12")
            self.end_headers()
            self.wfile.write(b"Unauthorized")
            return

        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

        try:
            data = json.loads(body)
            repo = data.get("repository", {}).get("full_name", "")
            sha = data.get("after", "")
            ref = data.get("ref", "")
            if repo and sha:
                enqueue(repo, sha, ref)
                log(f"Webhook received: {repo} {sha} {ref}")
        except (json.JSONDecodeError, KeyError, AttributeError) as e:
            log(f"WARNING: Failed to parse webhook payload: {e}")

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, format, *args):
        pass  # Suppress default access logs


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def main():
    os.makedirs(os.path.dirname(REVIEW_QUEUE), exist_ok=True)
    server = ThreadedHTTPServer(("", REVIEW_PORT), WebhookHandler)
    log(f"Webhook HTTP server listening on port {REVIEW_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Webhook HTTP server stopped")
        server.server_close()


if __name__ == "__main__":
    main()
