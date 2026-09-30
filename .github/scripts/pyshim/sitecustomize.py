"""CI-only shim: make socket.getfqdn() answer at once.

http.server.HTTPServer.server_bind() calls socket.getfqdn(host). On a GitHub
macOS runner the reverse lookup of 127.0.0.1 took 35 s (mDNS wait), so every
test that starts a python mock HTTP server gave up after 2-10 s. The tests need
only a loopback listener, not a resolved name.
"""
import socket

_real_getfqdn = socket.getfqdn


def _fast_getfqdn(name=""):
    if name in ("", "0.0.0.0", "127.0.0.1", "::1", "localhost"):
        return "localhost"
    return _real_getfqdn(name)


socket.getfqdn = _fast_getfqdn
