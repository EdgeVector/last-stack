"""Bounded identity metadata for an unchanged paired LDRHOME3 primary."""

import fcntl
import hashlib
import os
from pathlib import Path
import stat
import uuid
import zlib

from native_upgrade_common import require

NODE = b"format=3\nhome=disk-run\ncas=disk-cas\n"
MARKER = "laststore-pack-node-v1"
DESCRIPTOR = "laststore-run-home-v2"
STABLE = ("identity.key", ".bootstrap_done", "data/.device_id", "cloud_sync.json",
          "cloud_sync.json.paused", "org_sync_registration.json",
          "cloud-byte-backup-v2-manual.json", ".cloud_resume_required")


def identity(info):
    return {name: getattr(info, "st_" + name) for name in ("dev", "ino", "uid", "mode")}


def file_identity(info):
    return {**identity(info), **{name: getattr(info, "st_" + name)
                                for name in ("size", "mtime_ns", "nlink")}}


class Metadata:
    def __init__(self):
        self.directories = {}
        self.locks = []

    def directory(self, path, parent=None, name=None, private=True):
        require(path.is_absolute() and path.resolve() == path, "Run V2 metadata directory alias")
        fd = os.open(path if parent is None else name,
                     os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY, dir_fd=parent)
        try:
            info = os.fstat(fd)
            require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
                    and not info.st_mode & (0o077 if private else 0o022),
                    "Run V2 metadata directory ownership or mode differs")
            require(identity(info) == identity(path.lstat()), "Run V2 metadata directory changed")
            self.directories[path] = fd
            return fd
        except BaseException:
            os.close(fd)
            raise

    def file(self, parent, name, maximum, private=False, exact=None, optional=False):
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        except FileNotFoundError:
            require(optional, "Run V2 required metadata file is absent")
            return None, None
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                    and not before.st_mode & 0o022 and before.st_size <= maximum
                    and (not private or not before.st_mode & 0o077)
                    and (exact is None or before.st_size == exact),
                    "Run V2 metadata file ownership, type, or size differs")
            with os.fdopen(os.dup(fd), "rb") as source:
                data = source.read(maximum + 1)
            require(len(data) == before.st_size
                    and file_identity(before) == file_identity(os.fstat(fd))
                    == file_identity(os.stat(name, dir_fd=parent, follow_symlinks=False)),
                    "Run V2 metadata file changed during its read")
            return {**file_identity(before), "sha256": hashlib.sha256(data).hexdigest()}, data
        finally:
            os.close(fd)

    def close(self):
        try:
            for parent, name, fd, expected in self.locks:
                require(expected == file_identity(os.fstat(fd))
                        == file_identity(os.stat(name, dir_fd=parent, follow_symlinks=False)),
                        "Run V2 stopped owner lock changed")
            for path, fd in self.directories.items():
                require(identity(os.fstat(fd)) == identity(path.lstat()),
                        "Run V2 metadata directory changed during its read")
        finally:
            for _, _, fd, _ in self.locks:
                os.close(fd)
            for fd in self.directories.values():
                os.close(fd)

    def lock(self, parent, name, size, private=True):
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            info = os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                    and not info.st_mode & (0o077 if private else 0o022) and info.st_size == size,
                    "Run V2 stopped owner lock metadata differs")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            require(file_identity(info) == file_identity(os.fstat(fd))
                    == file_identity(os.stat(name, dir_fd=parent, follow_symlinks=False)),
                    "Run V2 stopped owner lock path changed")
            self.locks.append((parent, name, fd, file_identity(info)))
        except BaseException:
            os.close(fd)
            raise


def descriptor(metadata, parent):
    binding, data = metadata.file(parent, DESCRIPTOR, 64, exact=64)
    require(data[:8] == b"LDRHOME3" and int.from_bytes(data[8:12], "little") == 1
            and int.from_bytes(data[60:64], "little") == zlib.crc32(data[:60]),
            "Run V2 descriptor format or CRC32 differs")
    home_id = uuid.UUID(bytes=data[16:32])
    require(home_id.int != 0, "Run V2 descriptor identity is nil")
    return {**binding, "home_id": str(home_id)}


def bounded_file(path, maximum=1024 * 1024, private=False):
    path = Path(path)
    metadata = Metadata()
    try:
        parent = metadata.directory(path.parent, private=private)
        _, data = metadata.file(parent, path.name, maximum, private=private)
        return data
    finally:
        metadata.close()


def stable(home):
    home = Path(home)
    metadata = Metadata()
    try:
        root = metadata.directory(home, private=False)
        data = metadata.directory(home / "data", root, "data", private=False)
        values = {}
        for name in STABLE:
            parent, leaf = (data, name[5:]) if name.startswith("data/") else (root, name)
            binding, _ = metadata.file(parent, leaf, 1024 * 1024,
                                       private=name in ("identity.key", STABLE[-2], STABLE[-1]),
                                       optional=True)
            values[name] = None if binding is None else binding["sha256"]
        require(values["identity.key"] is not None and values["cloud_sync.json"] is None,
                "Run V2 requires its original identity and Cloud Off")
        marker, contents = metadata.file(data, MARKER, len(NODE), exact=len(NODE))
        require(contents == NODE, "Run V2 node marker differs")
        homes = {}
        for name in ("disk-run", "disk-cas"):
            fd = metadata.directory(home / "data" / name, data, name, private=False)
            lock, _ = metadata.file(fd, "LOCK", 0, private=True, exact=0)
            homes[name] = {"directory": identity(os.fstat(fd)),
                           "descriptor": descriptor(metadata, fd), "lock": lock}
        return {"files": values, "home": identity(os.fstat(root)),
                "data": identity(os.fstat(data)), "node_marker": marker, "run_homes": homes}
    finally:
        metadata.close()


def current_hash(parent):
    # The existing CURRENT encoded-file limit is 64 MiB. Only a fixed read
    # buffer is retained; this does not decode or change the native file.
    fd = os.open("CURRENT", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and not before.st_mode & 0o077 and 0 < before.st_size <= 64 * 1024 * 1024,
                "Run V2 stopped CURRENT metadata differs")
        result, count = hashlib.sha256(), 0
        with os.fdopen(os.dup(fd), "rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                count += len(block)
                require(count <= before.st_size, "Run V2 stopped CURRENT grew")
                result.update(block)
        require(count == before.st_size and file_identity(before) == file_identity(os.fstat(fd))
                == file_identity(os.stat("CURRENT", dir_fd=parent, follow_symlinks=False)),
                "Run V2 stopped CURRENT changed")
        return {"sha256": result.hexdigest(), "bytes": count}
    finally:
        os.close(fd)


def stopped_pair(home, expected):
    home = Path(home)
    metadata = Metadata()
    try:
        root = metadata.directory(home, private=False)
        data = metadata.directory(home / "data", root, "data", private=False)
        metadata.lock(data, MARKER, len(NODE), private=False)
        homes = {}
        for name in ("disk-run", "disk-cas"):
            homes[name] = metadata.directory(home / "data" / name, data, name, private=False)
            metadata.lock(homes[name], "LOCK", 0)
        require(stable(home) == expected, "Run V2 stopped native identity differs")
        result = {name: current_hash(fd) for name, fd in homes.items()}
        require(stable(home) == expected, "Run V2 stopped native identity changed")
        return result
    finally:
        metadata.close()
