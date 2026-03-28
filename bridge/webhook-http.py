#!/usr/bin/env python3
"""Threaded HTTP webhook receiver for TagBag Webhook Bridge.

Replaces the netcat-based listener to handle concurrent webhook deliveries.
Writes accepted webhooks to a queue file for the bash bridge consumer.
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

BRIDGE_PORT = int(os.environ.get("TAGBAG_BRIDGE_PORT", "9877"))
CONFIG_DIR = os.environ.get("TAGBAG_CONFIG_DIR", os.path.expanduser("~/.config/tagbag"))
BRIDGE_QUEUE = os.path.join(CONFIG_DIR, "bridge-queue")
BRIDGE_LOG = os.environ.get("BRIDGE_LOG", os.path.join(CONFIG_DIR, "bridge.log"))
WEBHOOK_SECRET = os.environ.get("GITEA_WEBHOOK_SECRET", "")
QUEUE_LOCK = BRIDGE_QUEUE + ".lock"


def log(msg):
    line = f"[{datetime.now().strftime('%Y-%m-%dT%H:%M:%S')}] {msg}"
    print(line, flush=True)
    try:
        with open(BRIDGE_LOG, "a") as f:
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


def enqueue(event_type: str, payload: str):
    """Write event to queue as: event_type<TAB>json_payload"""
    entry = f"{event_type}\t{payload}\n"
    fd = os.open(QUEUE_LOCK, os.O_WRONLY | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        with open(BRIDGE_QUEUE, "a") as f:
            f.write(entry)
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)
        signature = self.headers.get("X-Gitea-Signature", "")
        event_type = self.headers.get("X-Gitea-Event", "unknown")

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
            # Validate JSON
            json.loads(body)
            enqueue(event_type, body.decode("utf-8", errors="replace"))
            log(f"Webhook received: {event_type}")
        except (json.JSONDecodeError, KeyError) as e:
            log(f"WARNING: Failed to parse webhook payload: {e}")

    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, format, *args):
        pass


class ThreadedHTTPServer(ThreadingMixIn, HTTPServer):
    daemon_threads = True


def main():
    os.makedirs(os.path.dirname(BRIDGE_QUEUE), exist_ok=True)
    # Initialize empty queue
    open(BRIDGE_QUEUE, "a").close()
    server = ThreadedHTTPServer(("", BRIDGE_PORT), WebhookHandler)
    log(f"Bridge HTTP server listening on port {BRIDGE_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Bridge HTTP server stopped")
        server.server_close()


if __name__ == "__main__":
    main()
