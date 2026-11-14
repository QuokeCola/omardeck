#!/usr/bin/env python3
"""A pretend Hyprland for the tests, on sockets inside the sandbox.

Answers the requests Quickshell's Hyprland module makes from fixtures, writes
down everything it is asked, and does what the real one does with
hl.dsp.event("x"): raises it as custom>>x on the event socket. So the tests go
through the real raw-event path, and can see what was dispatched.

    fake-hypr.py <runtime dir> <signature> <log> <fixtures.json>
"""
import json
import os
import re
import socket
import sys
import threading

run, sig, log_path, fixtures = sys.argv[1:5]
base = os.path.join(run, "hypr", sig)
os.makedirs(base, exist_ok=True)
fx = json.load(open(fixtures))
listeners, lock = [], threading.Lock()
log = open(log_path, "a", buffering=1)


def emit(line):
    with lock:
        for c in list(listeners):
            try:
                c.sendall((line + "\n").encode())
            except OSError:
                listeners.remove(c)


def handle(conn):
    with conn:
        req = conn.recv(65536).decode(errors="replace").strip()
        log.write("socket " + req + "\n")
        m = re.match(r'(?:dispatch\s+)?hl\.dsp\.event\("(.*)"\)$', req)
        if m:
            emit("custom>>" + m.group(1))
        m = re.match(r"test/emit (.*)$", req)
        if m:
            emit(m.group(1))
        if req == "cursorpos":
            # The middle of the harness's X screen, where the overlay has no drift.
            reply = "800, 500"
        else:
            reply = json.dumps(fx.get(req[2:], [])) if req.startswith("j/") else "ok"
        conn.sendall(reply.encode())


def serve(path, on_conn):
    s = socket.socket(socket.AF_UNIX)
    s.bind(path)
    s.listen(16)
    while True:
        conn, _ = s.accept()
        on_conn(conn)


def on_event_client(conn):
    with lock:
        listeners.append(conn)


threading.Thread(target=serve, args=(os.path.join(base, ".socket2.sock"), on_event_client), daemon=True).start()
serve(os.path.join(base, ".socket.sock"),
      lambda conn: threading.Thread(target=handle, args=(conn,), daemon=True).start())
