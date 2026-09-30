#!/usr/bin/env python3
"""Fake LastDB UDS node for last-stack-load-collector tests.

usage: load-collector-fake-node.py <socket-path> ok|shed|hang
Serves until killed. `hang` accepts and never answers (a saturated node).
"""
import os
import socket
import sys
import threading
import time

path, mode = sys.argv[1], sys.argv[2]
if os.path.exists(path):
    os.unlink(path)
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(path)
srv.listen(16)


def handle(c):
    try:
        c.recv(4096)
        if mode == "hang":
            time.sleep(60)
        elif mode == "shed":
            body = b'{"status":"busy","error":"uds_worker_queue_full"}'
            c.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        else:
            body = b'{"status":"ok","phys_footprint_bytes":15032385536,"memory_budget":{"eviction_events":5,"governor_state":"under"},"sync":{"state":"degraded","degraded_reasons":["cloud_lag"]}}'
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
    finally:
        c.close()


while True:
    conn, _ = srv.accept()
    threading.Thread(target=handle, args=(conn,), daemon=True).start()
