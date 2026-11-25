"""Value-free failure classification and papercuts for the mechanical DEV worker."""
import re
import subprocess


def aws_failure(response, service, operation):
    # Match fixed SDK/CLI vocabulary only. Never retain the response, a signed
    # URL, provider key or account data in a log or error record.
    text = response.stderr[-8192:]
    classes = (
        ("expired-credentials", r"ExpiredToken|RequestExpired|SSO session.*expired"),
        ("credentials-unavailable", r"Unable to locate credentials|NoCredentials|credential.*not found"),
        ("credential-refused", r"InvalidClientTokenId|SignatureDoesNotMatch|InvalidAccessKeyId"),
        ("access-denied", r"AccessDenied|UnauthorizedOperation|Forbidden"),
        ("transport", r"Could not connect|EndpointConnection|timed out|SSL validation|NameResolution"),
        ("throttled", r"Throttl|TooManyRequests|SlowDown"),
        ("request-invalid", r"ValidationException|Unknown options|Parameter validation"),
    )
    category = next((name for name, pattern in classes if re.search(pattern, text, re.I)), "request-failed")
    return f"AWS operation refused: {service}/{operation} ({category}; exit={response.returncode})"


def failure_reason(error):
    if isinstance(error, RuntimeError):
        return str(error)
    if isinstance(error, KeyError):
        field = error.args[0] if error.args else ""
        if isinstance(field, str) and re.fullmatch(r"[a-z][a-z0-9_]{0,63}", field):
            return "cleanup metadata is missing field: " + field
        return "cleanup metadata is incomplete"
    return type(error).__name__


def report_errors(errors):
    for error in errors:
        result = subprocess.run(
            ["papercut", "file", "--title", "DEV proof cleanup blocked",
             "--symptom", error["reason"], "--component", "dev-proof-cleanup",
             "--repo", "EdgeVector/last-stack", "--severity", "p2", "--text", "-"],
            input=("The mechanical DEV cleanup retained its exact request. "
                   f"Stream: {error['stream_id']}. Reason: {error['reason']}. "
                   "Inspect its saved phase and ownership; do not clear holds or widen deletion targets."),
            capture_output=True, text=True, timeout=60)
        if result.returncode:
            raise RuntimeError("cleanup papercut filing failed")
