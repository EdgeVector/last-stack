"""Private source and I/O boundaries for the exact format4 DEV qualification."""

import hashlib
import importlib
import json
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import sys
import time
from types import SimpleNamespace

SOURCE = "a1c406f5d1dbfdd99b826be2e4854c025993a90b"
BASELINE = "1d4b205bb84ad3f6dc0a3b4c9d5088e13b499f46"
BASELINE_PROGRAMS = {
    "lastdb": "f94b96c5a820a19c76502c150c8b2815ff0d150dff86720c3f11f489976422ed",
    "lastdbd": "a53ac5ce39713574a47f9c8a9a38c337dd395c70a02212c217d2cf80d99c87d5",
}
MAX_FILE = 512 * 1024 * 1024
CHUNK = 1024 * 1024
MODULES = ("support", "programs", "node", "automatic_source", "restore_log", "restore_receipts")
SOURCES = tuple("scripts/cloud_backup/" + name + ".py" for name in MODULES) + (
    "folddb_profile/environments.json",
)


def require(condition, code):
    if not condition:
        raise RuntimeError(code)


def _path(path):
    path = Path(path)
    require(path.is_absolute() and path.resolve() == path, "absolute_exact_path")
    return path


def private_dir(path):
    path = _path(path)
    path.mkdir(mode=0o700, exist_ok=True)
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o700, "private_directory")
    return path


def _identity(info):
    return (info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_mode,
            info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def _open(path, maximum, private=False):
    path = _path(path)
    require(type(maximum) is int and 0 < maximum <= MAX_FILE, "file_bound")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and 0 <= info.st_size <= maximum
                and _identity(path.lstat()) == _identity(info), "owned_regular_file")
        require(not private or (info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600),
                "private_single_link_file")
        return path, descriptor, info
    except BaseException:
        os.close(descriptor)
        raise


def _stable(path, stream, before):
    require(_identity(before) == _identity(os.fstat(stream.fileno()))
            == _identity(path.lstat()) and path.resolve() == path, "file_changed")


def _object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "json_duplicate_key")
        result[key] = value
    return result


def _constant(_value):
    raise ValueError("json_nonfinite")


def read(path, maximum=262144):
    path, descriptor, before = _open(path, maximum, private=True)
    with os.fdopen(descriptor, "rb") as stream:
        raw = stream.read(maximum + 1)
        require(len(raw) <= maximum, "json_size")
        _stable(path, stream, before)
    try:
        return json.loads(raw.decode("utf-8"), object_pairs_hook=_object,
                          parse_constant=_constant)
    except (ValueError, UnicodeError):
        raise RuntimeError("json_invalid") from None


def hash_file(path, maximum=MAX_FILE):
    path, descriptor, before = _open(path, maximum)
    digest, total = hashlib.sha256(), 0
    with os.fdopen(descriptor, "rb") as stream:
        for block in iter(lambda: stream.read(CHUNK), b""):
            total += len(block)
            require(total <= maximum, "hash_size")
            digest.update(block)
        require(total == before.st_size, "hash_length")
        _stable(path, stream, before)
    return digest.hexdigest()


def native_file_hash(path, expected_bytes):
    """Hash the complete native payload with bounded buffers and no user file cap."""
    path = _path(path)
    require(type(expected_bytes) is int and 0 < expected_bytes <= 2**64 - 1, "native_expected_length")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and before.st_size == expected_bytes and _identity(path.lstat()) == _identity(before),
                "native_owned_regular_file")
        digest, total = hashlib.sha256(), 0
        while block := stream.read(min(CHUNK, expected_bytes - total + 1)):
            total += len(block)
            require(total <= expected_bytes, "native_length_changed")
            digest.update(block)
        require(total == expected_bytes, "complete_native_length")
        _stable(path, stream, before)
    return digest.hexdigest()


def _sync(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _write(path, raw):
    path = _path(path)
    private_dir(path.parent)
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    _sync(path.parent)
    return reference(path)


def save(path, value, maximum=262144):
    require(type(maximum) is int and 0 < maximum <= MAX_FILE, "json_bound")
    raw = (json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)
           + "\n").encode("utf-8")
    require(len(raw) <= maximum, "json_size")
    return _write(path, raw)


def reference(path):
    path = _path(path)
    return {"path": str(path), "sha256": hash_file(path)}


def _capture(command, maximum, timeout=30, environment=None):
    process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=environment, start_new_session=True)
    output = {"stdout": bytearray(), "stderr": bytearray()}
    limits = {"stdout": maximum, "stderr": 65536}
    deadline = time.monotonic() + timeout
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            while selector.get_map():
                require(time.monotonic() < deadline, "source_command_deadline")
                for key, _mask in selector.select(min(0.25, max(0, deadline - time.monotonic()))):
                    block = os.read(key.fileobj.fileno(), 65536)
                    if not block:
                        selector.unregister(key.fileobj)
                    else:
                        target = output[key.data]
                        require(len(target) + len(block) <= limits[key.data], "source_command_output")
                        target.extend(block)
        process.wait(timeout=max(0.1, deadline - time.monotonic()))
        require(process.returncode == 0, "source_command_refused")
        return bytes(output["stdout"])
    except subprocess.TimeoutExpired:
        raise RuntimeError("source_command_deadline") from None
    finally:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=10)
        process.stdout.close()
        process.stderr.close()


def secret(locator):
    require(isinstance(locator, str)
            and re.fullmatch(r"lastsecrets://[A-Za-z0-9][A-Za-z0-9._-]{0,127}", locator),
            "secret_locator")
    environment = dict(os.environ, OBS_SENTRY_DSN="", SENTRY_DSN="", POSTHOG_API_KEY="")
    try:
        raw = _capture([str(Path.home() / ".local/bin/lastsecrets"), "get", locator[14:]],
                       4096, environment=environment)
    except Exception:
        raise RuntimeError("secret_read_failed") from None
    value = raw.rstrip(b"\r\n")
    require(0 < len(value) <= 4096 and b"\0" not in value, "secret_size")
    return value


def freeze(repo, root):
    repo, root = _path(repo), private_dir(root)
    require(repo.is_dir(), "source_repository")
    top = _capture(["/usr/bin/git", "-C", str(repo), "rev-parse", "--show-toplevel"], 4096)
    require(top.decode("utf-8").strip() == str(repo), "source_repository_root")
    target = root / "source"
    require(not os.path.lexists(target), "frozen_source_exists")
    private_dir(target)
    for folder in ("scripts", "scripts/cloud_backup", "folddb_profile"):
        private_dir(target / folder)
    hashes = {}
    for name in SOURCES:
        raw = _capture(["/usr/bin/git", "-C", str(repo), "show", "--no-ext-diff",
                        "--no-textconv", SOURCE + ":" + name], CHUNK)
        require(bool(raw), "frozen_source_empty")
        hashes[name] = _write(target / name, raw)["sha256"]
    _sync(target)
    _sync(root)
    return hashes


def _frozen(root, hashes):
    require(isinstance(hashes, dict) and set(hashes) == set(SOURCES), "frozen_source_set")
    target = private_dir(private_dir(root) / "source")
    for name, expected in hashes.items():
        require(isinstance(expected, str) and re.fullmatch(r"[0-9a-f]{64}", expected),
                "frozen_source_digest")
        path, descriptor, _before = _open(target / name, CHUNK, private=True)
        os.close(descriptor)
        require(hash_file(path, CHUNK) == expected, "frozen_source_changed")
    return target


def imports(root, hashes):
    target = _frozen(root, hashes)
    folder = target / "scripts/cloud_backup"
    for name in MODULES:
        prior = sys.modules.get(name)
        require(prior is None or getattr(prior, "__file__", None) == str(folder / (name + ".py")),
                "foreign_source_module")
    prior_path, prior_bytecode = list(sys.path), sys.dont_write_bytecode
    try:
        sys.path.insert(0, str(folder))
        sys.dont_write_bytecode = True
        loaded = {name: importlib.import_module(name) for name in MODULES}
    finally:
        sys.path[:] = prior_path
        sys.dont_write_bytecode = prior_bytecode
    _frozen(root, hashes)
    require(all(getattr(module, "__file__", None) == str(folder / (name + ".py"))
                for name, module in loaded.items()), "foreign_source_module")
    return SimpleNamespace(support=loaded["support"], programs=loaded["programs"],
                           node=loaded["node"], source=loaded["automatic_source"],
                           restore=loaded["restore_receipts"])
