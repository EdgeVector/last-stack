"""Verify the ordinary Mini release archive without extraction or a local build."""

import gzip
import hashlib
import json
import os
import stat
import tarfile
import zipfile

from native_upgrade_common import require
from native_run_v2_inputs import external, parent_descriptor, unique
from native_v2_artifact import Bounded

MAXIMUM = 512 * 1024 * 1024
PACKAGE = "lastdb-aarch64-apple-darwin.tar.gz"
MANIFEST = "lastdb-aarch64-apple-darwin.manifest.json"


def identity(info):
    return (info.st_dev, info.st_ino, info.st_uid, info.st_mode,
            info.st_nlink, info.st_size, info.st_mtime_ns)


def hashed(stream, maximum):
    value, count = hashlib.sha256(), 0
    while block := stream.read(min(1024 * 1024, maximum + 1 - count)):
        count += len(block)
        require(count <= maximum, "A Mini archive member exceeds its bound")
        value.update(block)
    return value.hexdigest(), count


def manifest(archive, source, candidate):
    entry = archive.getinfo(MANIFEST)
    require(0 < entry.file_size <= 65536, "The Mini manifest exceeds its bound")
    with archive.open(entry) as stream:
        raw = stream.read(65537)
    require(len(raw) == entry.file_size, "The Mini manifest length differs")
    value = json.loads(raw, object_pairs_hook=unique,
                       parse_constant=lambda unused: require(False, "Nonfinite Mini metadata is forbidden"))
    require(isinstance(value, dict) and set(value) == {"schema", "target", "source_git_oid", "artifact", "binaries"}
            and value["schema"] == "lastdb.mini.bundle.v1"
            and value["target"] == "aarch64-apple-darwin" and value["source_git_oid"] == source,
            "The Mini archive source, target, or manifest schema differs")
    expected = [{"name": name, "sha256": candidate[name]["sha256"], "version": candidate[name]["version"]}
                for name in ("lastdb", "lastdbd")]
    require(value["binaries"] == expected and isinstance(value["artifact"], dict)
            and set(value["artifact"]) == {"file", "sha256"}
            and value["artifact"]["file"] == PACKAGE, "The Mini manifest does not bind the exact pair")
    package = archive.getinfo(PACKAGE)
    require(0 < package.file_size <= MAXIMUM, "The Mini package exceeds its bound")
    with archive.open(package) as stream:
        checksum, size = hashed(stream, package.file_size)
    require(size == package.file_size and checksum == value["artifact"]["sha256"],
            "The Mini package hash or length differs")
    return {"package_sha256": checksum, "manifest_sha256": hashlib.sha256(raw).hexdigest()}


def programs(archive, candidate):
    seen = set()
    with archive.open(PACKAGE) as packed, gzip.GzipFile(fileobj=packed) as expanded:
        with tarfile.open(fileobj=Bounded(expanded), mode="r|") as stream:
            for index, member in enumerate(stream):
                require(index < 8, "The Mini package member count exceeds its bound")
                name = member.name.removeprefix("./")
                if member.isdir() and name == ".":
                    continue
                require(member.isfile() and name in candidate and name not in seen
                        and 0 < member.size <= 256 * 1024 * 1024,
                        "The Mini package has an unexpected or oversized member")
                with stream.extractfile(member) as body:
                    checksum, size = hashed(body, member.size)
                require(size == member.size and checksum == candidate[name]["sha256"],
                        "A Mini executable differs from the exact selected CI pair")
                seen.add(name)
    require(seen == {"lastdb", "lastdbd"}, "The Mini package does not contain the complete pair")


def verify(path, source, candidate, expected_sha, expected_bytes):
    path = external(path)
    parent = parent_descriptor(path)
    descriptor = None
    try:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and before.st_mode & 0o077 == 0 and before.st_nlink == 1
                and 0 < before.st_size == expected_bytes <= MAXIMUM,
                "The original Mini ZIP has unsafe ownership or size")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            checksum, size = hashed(stream, MAXIMUM)
            require(size == expected_bytes and checksum == expected_sha, "The original Mini ZIP hash differs")
            stream.seek(0)
            with zipfile.ZipFile(stream) as archive:
                require(len(archive.infolist()) == 2 and set(archive.namelist()) == {PACKAGE, MANIFEST},
                        "The original Mini ZIP members differ")
                metadata = manifest(archive, source, candidate)
                programs(archive, candidate)
        current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        require(identity(before) == identity(os.fstat(descriptor)) == identity(current)
                and path.parent.resolve() == path.parent
                and os.fstat(parent).st_ino == path.parent.lstat().st_ino
                and os.fstat(parent).st_dev == path.parent.lstat().st_dev,
                "The original Mini ZIP or its anchored directory changed")
        return {"zip_sha256": checksum, "bytes": size, **metadata}
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)
