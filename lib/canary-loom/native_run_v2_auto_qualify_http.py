"""Preserve bounded refused responses privately; never retain request inputs."""
import hashlib
import http.client
import json
import os

from native_run_v2_auto_qualify_io import reference, require, save

MAX_ERROR_BYTES = 65536


def record(node, status, partial, complete, failure_class=None):
    """The response alone enters this receipt. No URL, request or headers do."""
    with node.http_lock:
        node.http_failures += 1
        index = node.http_failures
    require(index <= 64, "bounded_http_refusals")
    path = node.folder / ("http-response-" + str(index).zfill(3))
    path.mkdir(mode=0o700)
    kept = partial[:MAX_ERROR_BYTES]
    output = path / "response.bin"
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(kept)
        stream.flush()
        os.fsync(stream.fileno())
    value = {"schema": "lastdb.private-http-response.v1", "http_status": status,
        "body": reference(output), "retained_bytes": len(kept), "observed_bytes": len(partial),
        "body_sha256": hashlib.sha256(kept).hexdigest(), "truncated": len(partial) > MAX_ERROR_BYTES,
        "complete_response": complete and len(partial) <= MAX_ERROR_BYTES, "read_failure_class": failure_class,
        "request_retained": False, "headers_retained": False, "console_payload": False}
    node.http_last_response = save(path / "response.json", value)
    if status != 200:
        node.http_last_failure = node.http_last_response


def failure(node, response):
    partial, complete, failure_class = b"", False, None
    try:
        partial = response.read(MAX_ERROR_BYTES + 1)
        complete = len(partial) <= MAX_ERROR_BYTES
    except http.client.IncompleteRead as error:
        partial = error.partial[:MAX_ERROR_BYTES + 1]
        failure_class = "IncompleteRead"
    except (OSError, http.client.HTTPException) as error:
        failure_class = type(error).__name__
    record(node, response.status, partial, complete, failure_class)


def call(node, path, body=None, binary=False):
    connection = node.http_connection(node.socket)
    headers = {"X-LastDB-Client": "cloud-backup-ci", "Content-Type": "application/json"}
    if binary:
        headers["Accept"] = "application/octet-stream"
    content = None if body is None else json.dumps(body, separators=(",", ":")).encode()
    streaming = False
    try:
        connection.request("GET" if body is None else "POST", path, content, headers)
        response = connection.getresponse()
        node.http_last_status = response.status
        if response.status != 200:
            failure(node, response)
            require(False, "socket_http_status")
        if binary:
            streaming = True
            return response, connection
        raw = response.read(4 * 1024 * 1024 + 1)
        require(len(raw) <= 4 * 1024 * 1024, "socket_json_size")
        if getattr(node, "http_capture_success", False):
            record(node, response.status, raw, True)
        return node.http_decode(raw)
    finally:
        if not streaming:
            connection.close()
