"""Bounded, unauthenticated GET metadata for the fixed public LastDB repository."""

import json
import re
import resource
import subprocess
import tempfile
import time

from native_upgrade_common import require

REPOSITORY = "/repos/EdgeVector/lastdb"
MAXIMUM = 2 * 1024 * 1024
ROUTES = (
    r"/commits/[0-9a-f]{40}",
    r"/commits/[0-9a-f]{40}/check-runs\?filter=latest&per_page=100",
    r"/compare/[0-9a-f]{40}\.\.\.main\?per_page=1",
    r"/pulls/[1-9][0-9]{0,9}",
    r"/actions/artifacts/[1-9][0-9]{0,18}",
    r"/actions/runs/[1-9][0-9]{0,18}",
    r"/actions/runs/[1-9][0-9]{0,18}/jobs\?per_page=100",
    r"/actions/runs/[1-9][0-9]{0,18}/attempts/[1-9][0-9]{0,18}/jobs\?per_page=100",
    r"/actions/runs/[1-9][0-9]{0,18}/artifacts\?per_page=100",
    r"/check-runs/[1-9][0-9]{0,18}",
)


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Public provenance has duplicate JSON keys")
        result[key] = value
    return result


class PublicMetadata:
    def __init__(self):
        self.deadline, self.calls, self.public = time.monotonic() + 180, 0, False
        self.cache = {}

    def __call__(self, path):
        require(isinstance(path, str) and any(re.fullmatch(pattern, path) for pattern in ROUTES),
                "Public provenance refuses an unknown repository, route or method")
        if not self.public:
            repository = self.read("")
            require(repository.get("full_name") == "EdgeVector/lastdb"
                    and repository.get("private") is False, "The provenance repository is not public")
            self.public = True
        if path not in self.cache:
            self.cache[path] = self.read(path)
        return self.cache[path]

    def read(self, path):
        require(path == "" or any(re.fullmatch(pattern, path) for pattern in ROUTES),
                "Public provenance refuses an unknown route")
        remaining = self.deadline - time.monotonic()
        require(remaining > 0 and self.calls < 16, "Public provenance request budget exhausted")
        self.calls += 1
        # No curl configuration, netrc, proxy, credential, redirect or archive download.
        command = ["/usr/bin/curl", "--disable", "--no-netrc", "--noproxy", "*", "--proto", "=https",
                   "--request", "GET", "--silent", "--show-error", "--fail", "--max-redirs", "0",
                   "--connect-timeout", "10", "--max-time", str(min(30, remaining)),
                   "--header", "Accept: application/vnd.github+json", "--header", "X-GitHub-Api-Version: 2022-11-28",
                   "--user-agent", "LastStack-public-provenance", "--write-out", "%{http_code}"]
        def limits():
            resource.setrlimit(resource.RLIMIT_FSIZE, (MAXIMUM + 1, MAXIMUM + 1))
        with tempfile.NamedTemporaryFile(prefix="native-v2-public-", suffix=".json") as output:
            result = subprocess.run([*command, "--output", output.name, "https://api.github.com" + REPOSITORY + path],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False,
                                    timeout=min(35, remaining), preexec_fn=limits,
                                    env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"})
            require(result.returncode == 0 and result.stdout == b"200", "Public provenance is unavailable or rate limited")
            output.seek(0)
            raw = output.read(MAXIMUM + 1)
        require(0 < len(raw) <= MAXIMUM, "Public provenance response exceeds its bound")
        value = json.loads(raw, object_pairs_hook=unique,
                           parse_constant=lambda unused: require(False, "Public provenance has a nonfinite value"))
        require(isinstance(value, dict), "Public provenance requires a JSON object")
        return value
