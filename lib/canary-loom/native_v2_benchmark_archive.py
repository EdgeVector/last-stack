"""Read original CI evidence ZIPs with exact hashes and bounded metadata reads."""

from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import struct
import time
import zipfile

from native_upgrade_common import require
from native_v2_public import unique

MAXIMUM = 512 * 1024 * 1024


def identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_uid, info.st_mode)


@contextmanager
def archive(path, metadata, maximum):
    target = Path(path)
    require(target.is_absolute() and target.resolve() == target, "Benchmark archive path is not canonical")
    descriptor = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and before.st_mode & 0o077 == 0
                and 0 < before.st_size == metadata["size_in_bytes"] <= maximum,
                "The retained benchmark archive is not a bounded private file")
        digest, deadline, count = hashlib.sha256(), time.monotonic() + 120, 0
        while block := stream.read(min(1024 * 1024, maximum + 1 - count)):
            count += len(block)
            require(count <= maximum and time.monotonic() < deadline, "Benchmark archive exceeds its read budget")
            digest.update(block)
        require(count == before.st_size and "sha256:" + digest.hexdigest() == metadata["digest"],
                "Retained benchmark ZIP bytes differ from the GitHub artifact")
        expected_count = central_directory(stream, before.st_size)
        stream.seek(0)
        with zipfile.ZipFile(stream) as packed:
            entries = packed.infolist()
            require(len(entries) == expected_count and len({entry.filename for entry in entries}) == len(entries),
                    "Benchmark ZIP member enumeration is invalid")
            total = 0
            for entry in entries:
                name = PurePosixPath(entry.filename)
                kind = stat.S_IFMT(entry.external_attr >> 16)
                require(0 < len(entry.filename) <= 512 and not name.is_absolute() and ".." not in name.parts
                        and "\\" not in entry.filename and str(name) == entry.filename.rstrip("/")
                        and not entry.flag_bits & 1 and kind in (0, stat.S_IFREG, stat.S_IFDIR)
                        and entry.compress_type in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED),
                        "Benchmark ZIP contains an unsafe or encrypted member")
                total += entry.file_size
            require(total <= 2 * 1024**3, "Benchmark ZIP declared expansion exceeds its evidence bound")
            yield packed
        require(identity(os.fstat(stream.fileno())) == identity(before) == identity(target.lstat()),
                "The retained benchmark ZIP changed during validation")


def central_directory(stream, size):
    tail_start = max(0, size - 65557)
    stream.seek(tail_start)
    tail = stream.read(65557)
    offset = tail.rfind(b"PK\x05\x06")
    require(offset >= 0 and offset + 22 <= len(tail), "Benchmark ZIP has no bounded central directory")
    position = tail_start + offset
    stream.seek(max(0, position - 20))
    require(position < 20 or stream.read(4) != b"PK\x06\x07", "Benchmark evidence ZIP64 directories are unsupported")
    _, disk, start_disk, count, total, length, start, comment = struct.unpack_from("<4s4H2LH", tail, offset)
    require(disk == start_disk == 0 and count == total and 0 < total <= 8192
            and length <= 8 * 1024**2 and start + length <= position
            and offset + 22 + comment == len(tail), "Benchmark ZIP central directory is unsupported or oversized")
    return total


def document(packed, name):
    value = packed.getinfo(name)
    require(not value.is_dir() and 0 < value.file_size <= 1024 * 1024,
            "Benchmark metadata member is absent or oversized")
    total = getattr(packed, "_native_metadata_bytes", 0) + value.file_size
    require(total <= 8 * 1024 * 1024, "Selected benchmark metadata exceeds its evidence read budget")
    packed._native_metadata_bytes = total
    with packed.open(value) as stream:
        raw = stream.read(value.file_size + 1)
    require(len(raw) == value.file_size, "Benchmark metadata member is incomplete")
    result = json.loads(raw, object_pairs_hook=unique,
                        parse_constant=lambda unused: require(False, "Benchmark metadata has a nonfinite value"))
    require(isinstance(result, dict), "Benchmark metadata must be a JSON object")
    return result


def manifest(packed, prefix, source, baseline, builds):
    value = document(packed, prefix + "benchmark.json")
    require(type(value.get("format_version")) is int and value["format_version"] == 1
            and value.get("profile") == "standard" and value.get("complete") is True
            and value.get("driver_revision") == source and value.get("recipe", {}).get("native_timing") is False
            and type(value["recipe"].get("pairs")) is int and value["recipe"]["pairs"] == 2,
            "The exact standard benchmark manifest is incomplete")
    for label, revision in (("baseline", baseline), ("candidate", source)):
        binary = value["binaries"][label]
        require(binary.get("revision") == revision and all(binary.get(key) == builds[label][key]
                for key in ("sha256", "version")), "Benchmark binaries differ from their exact build receipts")
    rows = value.get("runs", [])
    expected = {(pair, label) for pair in range(2) for label in ("baseline", "candidate")}
    require(isinstance(rows, list) and len(rows) == 4 and all(isinstance(row, dict) for row in rows),
            "The standard benchmark lacks complete pairs")
    seen = set()
    for row in rows:
        pair, label = row.get("pair"), row.get("label")
        require(type(pair) is int and (pair, label) in expected and (pair, label) not in seen,
                "The standard benchmark has a missing or duplicate pair")
        seen.add((pair, label))
        directory = "pair-" + str(pair) + "-" + label
        revision = baseline if label == "baseline" else source
        require(row.get("directory") == directory and row.get("revision") == revision
                and row.get("complete") is True and row.get("error") is None, "A benchmark pair did not complete")
        result = document(packed, prefix + directory + "/result.json")
        require(result.get("complete") is True and result.get("error") is None and result.get("revision") == revision,
                "A retained benchmark pair result differs")
    require(document(packed, prefix + "comparison.json"), "A validated benchmark comparison is absent")


def verify(evidence, run, baseline):
    source, run_id = evidence["source_git_oid"], run["run_id"]
    metadata = run["artifacts"]
    with archive(evidence["candidate_benchmark_receipt_archive"], metadata["receipt"], 65536) as packed:
        require(packed.namelist() == ["artifact.json"], "The benchmark compact receipt ZIP differs")
        require(packed.getinfo("artifact.json").file_size <= 16384, "The benchmark compact receipt is oversized")
        receipt = document(packed, "artifact.json")
    url = "https://github.com/EdgeVector/lastdb/actions/runs/" + str(run_id)
    require(set(receipt) == {"url", "sha256", "source_revision", "command", "expires_at", "note"}
            and receipt["source_revision"] == source and "sha256:" + receipt["sha256"] == metadata["measurements"]["digest"]
            and receipt["url"] == url + "/artifacts/" + str(metadata["measurements"]["id"])
            and receipt["expires_at"] == metadata["measurements"]["expires_at"]
            and receipt["command"] == "gh run rerun " + str(run_id) + " -R EdgeVector/lastdb",
            "The original benchmark download receipt differs from its source or GitHub artifact")
    with archive(evidence["candidate_benchmark_archive"], metadata["measurements"], MAXIMUM) as packed:
        builds = {label: document(packed, "build-" + label + ".json") for label in ("baseline", "candidate")}
        require(builds["candidate"].get("mode") == "built from source"
                and builds["candidate"].get("producer") == url, "The exact benchmark candidate was not freshly built")
        for label, revision in (("baseline", baseline), ("candidate", source)):
            require(builds[label].get("revision") == revision and "bench-" + revision in builds[label].get("version", "")
                    and all(re.fullmatch(r"[0-9a-f]{64}", builds[label].get(key, "")) is not None
                            for key in ("sha256", "context")), "A benchmark build receipt differs from the exact source")
        require(builds["baseline"]["context"] == builds["candidate"]["context"], "Benchmark build contexts differ")
        manifest(packed, "", source, baseline, builds)
        manifest(packed, "resource-growth/", source, baseline, builds)
    return {"baseline": baseline, "candidate": source, "driver": source, "profile": "standard",
            "resource_only": False, "pairs": 2, "receipt_archive_sha256": metadata["receipt"]["digest"],
            "measurement_archive_sha256": metadata["measurements"]["digest"]}
