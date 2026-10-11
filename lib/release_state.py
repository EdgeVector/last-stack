"""Bounded owner-only release stage records. Never contain child output or keys."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
import stat
import tempfile
import re

MAX_RECEIPT_BYTES = 1024 * 1024


class ReceiptRefused(RuntimeError):
    """A static release receipt refusal."""


def read(path):
    try:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > MAX_RECEIPT_BYTES:
            raise ValueError
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise ValueError
        return value
    except (OSError, ValueError) as exc:
        raise ReceiptRefused("release receipt is missing, invalid or exceeds its bound") from exc


def write(path, value):
    encoded = (json.dumps(value, indent=2, sort_keys=True) + "\n").encode("utf-8")
    if len(encoded) > MAX_RECEIPT_BYTES:
        raise ReceiptRefused("release receipt exceeds its declared 1 MiB bound")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.exists() or path.is_symlink():
        read(path)
    descriptor, scratch = tempfile.mkstemp(prefix=".release-stage-", dir=str(path.parent))
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(scratch, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(scratch):
            os.unlink(scratch)


def prior(root, build, oid):
    digest = hashlib.sha256((build + "\n" + oid).encode()).hexdigest()
    path = root / "release-attempts" / (digest + ".json")
    if not path.exists() and not path.is_symlink():
        return None
    value = read(path)
    if value.get("lastdb_version") != build or value.get("source_git_oid") != oid:
        raise ReceiptRefused("release attempt identity differs")
    return value


class ReleaseState:
    def __init__(self, root, summary):
        digest = hashlib.sha256((summary["lastdb_version"] + "\n" + summary["source_git_oid"]).encode()).hexdigest()
        self.path = root / "release-attempts" / (digest + ".json")
        self.summary = summary
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        try:
            descriptor = os.open(self.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError as exc:
            previous = read(self.path)
            if previous.get("lastdb_version") != summary["lastdb_version"] or previous.get("source_git_oid") != summary["source_git_oid"]:
                raise ReceiptRefused("release attempt identity differs") from exc
            summary.clear()
            summary.update(previous)
            summary["recovery_receipt"] = str(self.path)
            raise ReceiptRefused("a prior exact release attempt exists; reconcile its recorded tag and outputs before retry") from exc
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(b"{}\n")
            stream.flush()
            os.fsync(stream.fileno())
        self.save()

    def save(self):
        self.summary["updated_at"] = dt.datetime.now(dt.timezone.utc).isoformat()
        write(self.path, self.summary)

    def stage(self, half, stage, **fields):
        value = self.summary.setdefault("publication", {}).setdefault(half, {})
        value.update(fields)
        value["stage"] = stage
        self.save()

    def formula_proof(self, path):
        proof = read(path)
        if proof.get("version_tag") != self.summary["stable_tag"] or proof.get("release_repo") != "EdgeVector/homebrew-lastdb":
            raise ReceiptRefused("formula partial receipt identity differs")
        publication = proof.get("publication")
        if not isinstance(publication, dict) or publication.get("source_git_oid") != self.summary["source_git_oid"]:
            raise ReceiptRefused("formula partial receipt source differs")
        outputs = proof.get("live_outputs")
        if not isinstance(outputs, dict):
            raise ReceiptRefused("formula partial receipt outputs differ")
        release_url = outputs.get("release_url", "")
        pr_url = outputs.get("tap_pr_url", "")
        if release_url and release_url != "https://github.com/EdgeVector/homebrew-lastdb/releases/tag/" + self.summary["stable_tag"]:
            raise ReceiptRefused("formula partial receipt release differs")
        if pr_url and not re.fullmatch(r"https://github.com/EdgeVector/homebrew-lastdb/pull/[0-9]+", pr_url):
            raise ReceiptRefused("formula partial receipt PR differs")
        self.summary.setdefault("publication", {})["brew"] = {**publication, **outputs, "proof_receipt": str(path)}
        self.summary["brew"] = pr_url or publication.get("stage", "requested")
        self.save()
