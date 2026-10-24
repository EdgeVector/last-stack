"""Read the verified CI archive without extraction or a product build."""

import gzip
import hashlib
from pathlib import Path
import tarfile
import zipfile

from native_upgrade_common import regular, require

MAXIMUM = 512 * 1024 * 1024


class Bounded:
    def __init__(self, stream):
        self.stream, self.remaining = stream, MAXIMUM + 1024 * 1024

    def read(self, size=-1):
        size = self.remaining + 1 if size < 0 else min(size, self.remaining + 1)
        data = self.stream.read(size)
        require(len(data) <= self.remaining, "CI archive expansion exceeds its bound")
        self.remaining -= len(data)
        return data


def verify(path, source, candidate):
    regular(path, private=True, maximum=MAXIMUM)
    expected = {"bin/lastdb", "bin/lastdbd", "SOURCE_COMMIT", "TARGET", "VERSION", "SHA256SUMS"}
    seen, values, checksums = set(), {}, {}
    with zipfile.ZipFile(Path(path)) as archive:
        require(archive.namelist() == ["lastdb-native-dev-arm64.tar.gz"], "CI archive members differ")
        info = archive.infolist()[0]
        require(0 < info.file_size <= MAXIMUM, "CI archive length exceeds its bound")
        with archive.open(info) as packed, gzip.GzipFile(fileobj=packed) as expanded:
            with tarfile.open(fileobj=Bounded(expanded), mode="r|") as stream:
                for index, member in enumerate(stream):
                    require(index < 16, "CI archive member count exceeds its bound")
                    name = member.name.removeprefix("./")
                    if member.isdir() and name in (".", "bin"):
                        continue
                    require(member.isfile() and name in expected and name not in seen,
                            "CI archive has an unexpected member")
                    limit = 256 * 1024 * 1024 if name.startswith("bin/") else 65536
                    require(0 < member.size <= limit, "CI archive member exceeds its bound")
                    digest, count, metadata = hashlib.sha256(), 0, []
                    body = stream.extractfile(member)
                    while block := body.read(min(1024 * 1024, member.size + 1 - count)):
                        count += len(block)
                        require(count <= member.size, "CI archive member length differs")
                        digest.update(block)
                        if not name.startswith("bin/"):
                            metadata.append(block)
                    require(count == member.size, "CI archive member is incomplete")
                    checksums[name] = digest.hexdigest()
                    if metadata:
                        values[name] = b"".join(metadata).decode().strip()
                    seen.add(name)
    require(seen == expected and values["SOURCE_COMMIT"] == source
            and values["TARGET"] == "aarch64-apple-darwin", "CI source or target differs")
    require(all(checksums["bin/" + name] == value["sha256"] for name, value in candidate.items()),
            "Candidate program bytes differ from the exact CI archive")
