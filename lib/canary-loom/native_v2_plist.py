"""Read one unchanged owner-controlled LaunchAgent in a macOS plist format."""

import hashlib
import os
import plistlib
import resource
import stat
import subprocess
import tempfile
from xml.parsers.expat import ExpatError

from native_upgrade_common import require

INPUT_BYTES = 1024 * 1024
CONVERTED_BYTES = 8 * 1024 * 1024
PARSE_ERRORS = (plistlib.InvalidFileException, ExpatError, ValueError)


def limit_conversion():
    _, hard = resource.getrlimit(resource.RLIMIT_FSIZE)
    ceiling = CONVERTED_BYTES if hard == resource.RLIM_INFINITY else min(CONVERTED_BYTES, hard)
    resource.setrlimit(resource.RLIMIT_FSIZE, (ceiling, ceiling))


def parse(data):
    try:
        return plistlib.loads(data)
    except PARSE_ERRORS:
        # The input and output paths are both '-'. No named plist is rewritten.
        # The anonymous private output prevents pipe buffering and bounds every
        # byte the converter can emit, including expanded binary references.
        with tempfile.TemporaryFile() as output:
            converted = subprocess.run(
                ["/usr/bin/plutil", "-convert", "xml1", "-o", "-", "--", "-"],
                input=data, stdout=output, stderr=subprocess.DEVNULL, timeout=10,
                preexec_fn=limit_conversion,
            )
            require(converted.returncode == 0, "The LaunchAgent format is invalid or unsupported")
            output.seek(0)
            raw = output.read(CONVERTED_BYTES + 1)
        require(0 < len(raw) <= CONVERTED_BYTES, "Converted LaunchAgent exceeds its bound")
        try:
            return plistlib.loads(raw)
        except PARSE_ERRORS:
            raise RuntimeError("The converted LaunchAgent format is unsupported") from None


def identity(info):
    return tuple(getattr(info, "st_" + name) for name in
                 ("dev", "ino", "uid", "mode", "size", "mtime_ns", "nlink"))


def read_agent(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and not before.st_mode & 0o022 and 0 < before.st_size <= INPUT_BYTES,
                "The LaunchAgent must be a bounded owner-controlled regular file")
        with os.fdopen(os.dup(fd), "rb") as source:
            data = source.read(INPUT_BYTES + 1)
        require(len(data) == before.st_size, "The LaunchAgent length changed")
        value = parse(data)
        require(identity(before) == identity(os.fstat(fd)) == identity(path.lstat()),
                "The LaunchAgent changed during its read")
        require(isinstance(value, dict), "The LaunchAgent must contain a dictionary")
        return value, hashlib.sha256(data).hexdigest()
    finally:
        os.close(fd)
