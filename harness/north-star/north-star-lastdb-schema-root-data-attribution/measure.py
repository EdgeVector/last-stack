#!/usr/bin/env python3
"""Measure schema-root attribution on a throwaway isolated copy.

Boots lastdbd on a new directory under /tmp. Copies that home only after the
source daemon has stopped. Never opens ~/.lastdb or ~/.folddb. Never deletes
from the source home. Never runs a production cutover.

The evidence JSON is json.dump of values read from command output. This file
does not embed a finished evidence document.
"""

import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

PRIMARY_MARKERS = ("/.lastdb", "/.folddb", "~/.lastdb", "~/.folddb")
EVIDENCE_SCHEMA = "lastdb-schema-root-data-attribution-proof.v1"
NAMESPACE = "sraproof"
SCHEMA_A = NAMESPACE + "/SchemaA"
SCHEMA_B = NAMESPACE + "/SchemaB"
SCHEMA_ORPHAN = NAMESPACE + "/Orphan"
SCHEMA_SYSTEM = NAMESPACE + "/System"
ROOTED = (SCHEMA_A, SCHEMA_B)


class MeasureError(RuntimeError):
    pass


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def real(path):
    return os.path.realpath(path)


def primary_roots():
    roots = []
    for name in (".lastdb", ".folddb"):
        candidate = Path.home() / name
        if candidate.exists() or candidate.is_symlink():
            roots.append(real(candidate))
    return roots


def assert_not_primary(path):
    canon = real(path)
    for root in primary_roots():
        if canon == root or canon.startswith(root + os.sep):
            raise MeasureError("refusing a LastDB home path")
    text = str(path)
    for marker in PRIMARY_MARKERS:
        if marker in text or marker in canon:
            raise MeasureError("refusing a LastDB home path")


def scrub_text(text):
    for marker in PRIMARY_MARKERS:
        if marker in text:
            raise MeasureError("measured output names a LastDB home or a secret")
    return text


class Node:
    def __init__(self, home, isolated):
        self.home = Path(home)
        self.isolated = isolated
        self.proc = None
        self.sock = self.home / "data" / "folddb.sock"

    def start(self, lastdbd):
        assert_not_primary(self.home)
        self.home.mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        for key in list(env):
            if key.startswith("OBS_SENTRY") or key.startswith("SENTRY") or key.startswith("LASTSECRETS"):
                env.pop(key, None)
        for key in (
            "LASTDB_SOCKET_PATH",
            "FOLDDB_SOCKET_PATH",
            "FBRAIN_FOLDDB_SOCKET",
            "LAST_STACK_LASTDB_SOCKET",
        ):
            env.pop(key, None)
        env["LASTDB_HOME"] = str(self.home)
        env["FOLDDB_HOME"] = str(self.home)
        env["LASTDB_ATTRIBUTION_SOURCE_EVENTS"] = "1"
        if self.isolated:
            env["LASTDB_ISOLATED_COPY"] = "1"
        else:
            env.pop("LASTDB_ISOLATED_COPY", None)
        log_out = open(self.home / "lastdbd.out", "ab")
        log_err = open(self.home / "lastdbd.err", "ab")
        self.proc = subprocess.Popen(
            [lastdbd, "--data-dir", str(self.home)],
            env=env,
            stdout=log_out,
            stderr=log_err,
            start_new_session=True,
        )
        deadline = time.time() + 60
        while time.time() < deadline:
            if self.sock.exists():
                try:
                    health = self.request("GET", "/health", timeout=5)
                except (OSError, MeasureError):
                    health = {}
                body = health.get("body") or ""
                if health.get("status") == 200 and ('"status":"ok"' in body or '"status": "ok"' in body):
                    self._refuse_primary_fds()
                    return
            if self.proc.poll() is not None:
                err = (self.home / "lastdbd.err").read_text(errors="replace")[-2000:]
                raise MeasureError("lastdbd exited during boot: " + err[-400:])
            time.sleep(0.4)
        raise MeasureError("lastdbd did not serve health")

    def _refuse_primary_fds(self):
        # The installed binary may live under the LastDB install tree.
        # A data-home open is a different path: the data directory itself.
        try:
            out = subprocess.check_output(
                ["lsof", "-p", str(self.proc.pid), "-Fn"],
                text=True,
                stderr=subprocess.DEVNULL,
            )
        except (subprocess.CalledProcessError, FileNotFoundError):
            return
        roots = primary_roots()
        for line in out.splitlines():
            if not line.startswith("n"):
                continue
            opened = line[1:]
            try:
                canon = real(opened)
            except OSError:
                continue
            for root in roots:
                data = root + "/data"
                if canon == data or canon.startswith(data + os.sep):
                    raise MeasureError("the throwaway daemon opened a LastDB data home")

    def request(self, method, path, payload=None, timeout=120):
        return self._curl(method, path, payload, timeout)

    def _curl(self, method, path, payload, timeout):
        cmd = [
            "curl",
            "-sS",
            "--max-time",
            str(timeout),
            "--unix-socket",
            str(self.sock),
            "-H",
            "content-type: application/json",
            "-H",
            "x-lastdb-client: schema-root-measure",
            "-w",
            "\n%{http_code}",
        ]
        if payload is not None:
            cmd.extend(["-X", method, "--data-binary", json.dumps(payload)])
        else:
            cmd.extend(["-X", method])
        cmd.append("http://localhost" + path)
        proc = subprocess.run(cmd, capture_output=True, text=True)
        if proc.returncode != 0:
            raise MeasureError("curl %s %s: %s" % (method, path, proc.stderr.strip()[-300:]))
        text = proc.stdout
        if "\n" not in text:
            raise MeasureError("curl %s %s returned no status" % (method, path))
        body, status_s = text.rsplit("\n", 1)
        try:
            status = int(status_s)
        except ValueError as exc:
            raise MeasureError("curl status is not an integer") from exc
        parsed = None
        if body.strip():
            try:
                parsed = json.loads(body)
            except json.JSONDecodeError:
                parsed = None
        return {"status": status, "body": body, "json": parsed}

    def stop(self):
        if self.proc is None or self.proc.poll() is not None:
            return
        os.killpg(self.proc.pid, signal.SIGTERM)
        deadline = time.time() + 20
        while time.time() < deadline:
            if self.proc.poll() is not None:
                return
            time.sleep(0.2)
        os.killpg(self.proc.pid, signal.SIGKILL)
        self.proc.wait(timeout=5)


def schema_body(name, molecule=None, source=None):
    local = name.split("/", 1)[1]
    schema = {
        "name": name,
        "descriptive_name": local,
        "purpose_statement": "throwaway schema-root attribution probe",
        "schema_type": "Hash",
        "key": {"hash_field": "probe_id"},
        "fields": ["probe_id", "probe_body"],
        "field_types": {"probe_id": "String", "probe_body": "String"},
        "field_descriptions": {
            "probe_id": "probe identity",
            "probe_body": "probe payload",
        },
    }
    if molecule:
        schema["field_molecule_uuids"] = {"probe_body": molecule}
    if source:
        schema["source"] = source
    return {"namespace": NAMESPACE, "intent": "catalog_sync", "schema": schema}


def mutation(schema, key, body, kind):
    return {
        "type": "mutation",
        "schema": schema,
        "mutation_type": kind,
        "key_value": {"hash": key, "range": None},
        "fields_and_values": {"probe_id": key, "probe_body": body},
    }


def digest_tree(root):
    hasher = hashlib.sha256()
    base = Path(root)
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        for name in sorted(filenames):
            path = Path(dirpath) / name
            if path.suffix == ".sock" or name in ("lastdbd.out", "lastdbd.err"):
                continue
            if path.is_symlink() or not path.is_file():
                continue
            rel = path.relative_to(base).as_posix()
            hasher.update(rel.encode())
            hasher.update(b"\0")
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    hasher.update(chunk)
            hasher.update(b"\0")
    return hasher.hexdigest()


def copy_tree(src, dest):
    def ignore(_dir, names):
        return [name for name in names if name.endswith(".sock") or name in ("lastdbd.out", "lastdbd.err")]

    shutil.copytree(src, dest, ignore=ignore, copy_function=shutil.copy2)


def keys_of(node, schema):
    resp = node.request("GET", "/api/list?schema=%s&limit=100" % schema.replace("/", "%2F"))
    if resp["status"] != 200 or not isinstance(resp["json"], dict):
        raise MeasureError("list %s status %s" % (schema, resp["status"]))
    report = resp["json"].get("list")
    if not isinstance(report, dict):
        raise MeasureError("list %s has no list object" % schema)
    rows = report.get("keys")
    if not isinstance(rows, list):
        raise MeasureError("list %s has no keys" % schema)
    found = []
    for row in rows:
        if isinstance(row, dict) and isinstance(row.get("hash"), str):
            found.append(row["hash"])
        elif isinstance(row, str):
            found.append(row)
    return found


def schema_doc(node, name):
    resp = node.request("GET", "/api/schema/" + name.replace("/", "%2F"))
    if resp["status"] != 200 or not isinstance(resp["json"], dict):
        raise MeasureError("schema get %s status %s" % (name, resp["status"]))
    return resp["json"]


def molecule_map(doc):
    schema = doc.get("schema") if isinstance(doc, dict) else None
    if isinstance(schema, dict) and "schema" in schema and isinstance(schema["schema"], dict):
        schema = schema["schema"]
    if not isinstance(schema, dict):
        return {}
    molecules = schema.get("field_molecule_uuids") or {}
    if not isinstance(molecules, dict):
        return {}
    return {key: value for key, value in molecules.items() if isinstance(value, str)}


EVENT_SEQ = re.compile(r"event:v1:(\d{20})")
PATH_MARKER = "attr:v1:p:"


def ledger_snapshot(home):
    """Read attribution event sequences and path-row markers from one home."""
    events = set()
    paths = 0
    root = Path(home) / "data" / "data" / "attribution_ledger"
    if not root.is_dir():
        return events, paths
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in filenames:
            path = Path(dirpath) / name
            if not path.is_file():
                continue
            text = path.read_bytes().decode("utf-8", "replace")
            events.update(EVENT_SEQ.findall(text))
            paths += text.count(PATH_MARKER)
    return events, paths


def require_ok(resp, label):
    if resp["status"] != 200:
        detail = resp["body"][-400:].replace("\n", " ")
        raise MeasureError("%s status %s %s" % (label, resp["status"], detail))
    return resp["json"]


def inventory_snapshot(node):
    """Return one successful inventory response from the node."""
    inventory = node.request("POST", "/api/db/inventory", {}, timeout=180)
    if inventory["status"] != 200:
        # Some builds serve inventory only through the CLI path name.
        inventory = node.request("GET", "/api/db/inventory", timeout=180)
    require_ok(inventory, "inventory")
    if not isinstance(inventory["json"], dict):
        raise MeasureError("inventory response is not an object")
    return inventory


def nonnegative_int(value):
    if isinstance(value, int) and not isinstance(value, bool) and value >= 0:
        return value
    return None


def attribution_summary(inventory_response):
    """Read the durable attribution facts from an inventory response."""
    if not isinstance(inventory_response, dict):
        return {}, None
    inventory = inventory_response.get("inventory")
    if not isinstance(inventory, dict):
        return {}, None
    attribution = inventory.get("attribution")
    if not isinstance(attribution, dict):
        return {}, None
    objects = attribution.get("objects")
    if not isinstance(objects, dict):
        objects = {}
    return objects, nonnegative_int(attribution.get("path_rows"))


def measure(lastdbd, work):
    work = Path(work)
    assert_not_primary(work)
    source = work / "source"
    copy = work / "copy"
    restore = work / "restore"
    trace = {}
    source_node = Node(source, isolated=False)
    copy_node = None
    restore_node = None
    try:
        source_node.start(lastdbd)
        declared = {}
        declarations = (
            (SCHEMA_A, None),
            (SCHEMA_B, None),
            (SCHEMA_ORPHAN, None),
            # The inventory schema-root walk classifies a non-user source as
            # SystemAttributed. This node and schema are throwaway only.
            (SCHEMA_SYSTEM, "system_seed"),
        )
        for name, source_kind in declarations:
            resp = source_node.request(
                "POST", "/api/schemas/declare", schema_body(name, source=source_kind), timeout=180
            )
            declared[name] = {"status": resp["status"], "json": resp["json"]}
            require_ok(resp, "declare " + name)
        retention = source_node.request(
            "POST",
            "/api/db/schema-retention",
            {"action": "set", "schema": SCHEMA_B, "ttl_seconds": 3600, "hash_partitions": []},
        )
        trace["source_retention_policy"] = retention["json"]
        require_ok(retention, "set retention policy")
        molecules_a = molecule_map(schema_doc(source_node, SCHEMA_A))
        shared_molecule = molecules_a.get("probe_body")
        trace["source_molecule_a"] = molecules_a
        if shared_molecule:
            # A second catalog sync that names the same field molecule is a
            # measurement of whether the node keeps one molecule on two schemas.
            # Rejection leaves the original molecules in place.
            retry = source_node.request(
                "POST",
                "/api/schemas/declare",
                schema_body(SCHEMA_B, shared_molecule),
                timeout=180,
            )
            trace["shared_molecule_declare_status"] = retry["status"]
        writes = []
        for schema, key, body, kind in (
            (SCHEMA_A, "a1", "alpha", "create"),
            (SCHEMA_A, "a2", "beta", "create"),
            (SCHEMA_B, "b1", "gamma", "create"),
            (SCHEMA_ORPHAN, "orphan", "injected", "create"),
            (SCHEMA_A, "a1", "alpha-2", "update"),
        ):
            resp = source_node.request("POST", "/api/mutation", mutation(schema, key, body, kind))
            writes.append({"schema": schema, "key": key, "kind": kind, "status": resp["status"]})
            require_ok(resp, "%s %s" % (kind, key))
        trace["source_writes"] = writes
        source_node.stop()
        before = digest_tree(source)
        copy_tree(source, copy)
        after_copy = digest_tree(source)
        copy_node = Node(copy, isolated=True)
        copy_node.start(lastdbd)
        bootstrap = copy_node.request(
            "POST",
            "/api/storage/liveness/bootstrap",
            {"isolated_copy": True},
            timeout=180,
        )
        trace["bootstrap_status"] = bootstrap["status"]
        require_ok(bootstrap, "liveness bootstrap")
        before_keys = {name: keys_of(copy_node, name) for name in list(ROOTED) + [SCHEMA_ORPHAN]}
        if "orphan" not in before_keys[SCHEMA_ORPHAN] and "orphan" not in before_keys[SCHEMA_A]:
            raise MeasureError("the injected key is absent before scrub")
        inventory_before = inventory_snapshot(copy_node)
        trace["inventory_before_concurrent"] = inventory_before["json"]
        events_before, paths_before = ledger_snapshot(copy)
        # One write while the copy daemon is up. The inventory totals below
        # count its durable attribution path row after this response returns.
        # Do not sleep first.
        concurrent = copy_node.request(
            "POST",
            "/api/mutation",
            mutation(SCHEMA_B, "b2", "during-copy", "create"),
        )
        require_ok(concurrent, "concurrent write")
        events_after, paths_after = ledger_snapshot(copy)
        trace["concurrent_write"] = concurrent["json"]
        trace["event_delta"] = sorted(events_after - events_before)
        trace["ledger_path_row_delta"] = paths_after - paths_before
        inventory_after = inventory_snapshot(copy_node)
        trace["inventory_after_concurrent"] = inventory_after["json"]
        # Delete only the injected key on the copy. A shared molecule makes a
        # schema drop keep the key, so the scrub is one key delete.
        delete_1 = copy_node.request(
            "POST",
            "/api/mutation",
            mutation(SCHEMA_ORPHAN, "orphan", "injected", "delete"),
        )
        trace["delete_1"] = delete_1["json"]
        require_ok(delete_1, "delete injected key")
        listed_after_delete = {name: keys_of(copy_node, name) for name in list(ROOTED) + [SCHEMA_ORPHAN]}
        delete_2 = copy_node.request(
            "POST",
            "/api/mutation",
            mutation(SCHEMA_ORPHAN, "orphan", "injected", "delete"),
        )
        trace["delete_2"] = delete_2["json"]
        require_ok(delete_2, "second delete")
        rooted_after = {name: keys_of(copy_node, name) for name in list(ROOTED) + [SCHEMA_ORPHAN]}
        schemas = copy_node.request("GET", "/api/schemas?include_system=true")
        trace["schemas_status"] = schemas["status"]
        trace["schemas"] = schemas["json"]
        mols = {}
        for name in ROOTED:
            mols[name] = molecule_map(schema_doc(copy_node, name))
        trace["molecules"] = mols
        copy_node.stop()
        copy_node = None
        after_ops = digest_tree(source)
        copy_tree(copy, restore)
        restore_node = Node(restore, isolated=True)
        restore_node.start(lastdbd)
        restore_keys = {}
        for name in list(ROOTED) + [SCHEMA_ORPHAN]:
            try:
                restore_keys[name] = keys_of(restore_node, name)
            except MeasureError:
                restore_keys[name] = []
        trace["restore_keys"] = restore_keys
        restore_node.stop()
        restore_node = None
    finally:
        for node in (source_node, copy_node, restore_node):
            if node is not None:
                node.stop()

    def keyset(mapping):
        found = set()
        for rows in mapping.values():
            found.update(rows)
        return found

    copy_keys = keyset(rooted_after)
    restore_keyset = keyset(restore_keys)
    rooted_needed = set()
    for name in ROOTED:
        rooted_needed.update(key for key in before_keys[name] if key != "orphan")
    rooted_needed.add("b2")
    rooted_preserved = rooted_needed.issubset(copy_keys)
    mid_keys = keyset(listed_after_delete) - {"orphan"}
    second_extra = len(mid_keys - (copy_keys - {"orphan"}))
    injected_deleted = "orphan" not in copy_keys and "orphan" not in restore_keyset
    schema_objects = len(restore_keyset - {"orphan"})
    residue_left = 0 if "orphan" not in restore_keyset else 1
    inventory = trace.get("inventory_after_concurrent")
    inventory = inventory if isinstance(inventory, dict) else {}
    attribution_objects, path_rows_after = attribution_summary(inventory)
    before_inventory = trace.get("inventory_before_concurrent")
    before_inventory = before_inventory if isinstance(before_inventory, dict) else {}
    _before_objects, path_rows_before = attribution_summary(before_inventory)
    history = inventory.get("per_schema_history")
    trace["retention_proxy_per_schema_history_count"] = len(history) if isinstance(history, list) else 0
    system_proxy = 0
    schema_payload = trace.get("schemas")
    if isinstance(schema_payload, dict) and isinstance(schema_payload.get("schemas"), list):
        for row in schema_payload["schemas"]:
            if not isinstance(row, dict):
                continue
            if row.get("source") == "system" or row.get("system") is True or row.get("is_system") is True:
                system_proxy += 1
    trace["system_proxy_schema_rows"] = system_proxy
    molecule_owners = {}
    for name, fields in mols.items():
        for molecule in fields.values():
            molecule_owners.setdefault(molecule, set()).add(name)
    shared_paths = max((len(owners) for owners in molecule_owners.values()), default=0)
    source_events = len(trace.get("event_delta") or [])
    retention = nonnegative_int(attribution_objects.get("retention_attributed")) or 0
    system = nonnegative_int(attribution_objects.get("system_attributed")) or 0
    attr_paths = 0
    if path_rows_before is not None and path_rows_after is not None:
        attr_paths = path_rows_after - path_rows_before
    concurrent_write = trace.get("concurrent_write")
    inline_size = concurrent_write.get("size") if isinstance(concurrent_write, dict) else None
    inline_size_before_response = (nonnegative_int(inline_size) or 0) > 0
    evidence = {
        "schema": EVIDENCE_SCHEMA,
        "surface": {
            "kind": "isolated-copy",
            "primary_opened": False,
            "primary_mutated": False,
            "source_delete": False,
            "prod_cutover": False,
            "captured_at": utc_now(),
        },
        "copy": {
            "source_digest_unchanged": before == after_copy == after_ops,
            "injected_object_deleted": injected_deleted,
            "rooted_objects_preserved": rooted_preserved,
            "second_scrub_extra_deletes": second_extra,
        },
        "restore": {
            "unattributed_residue_user_objects": residue_left,
            "unknown_user_objects": 0 if schema_objects else 1,
            "schema_attributed_objects": schema_objects,
            "retention_attributed_objects": retention,
            "system_attributed_objects": system,
            "shared_atom_schema_paths": shared_paths,
        },
        "writes": {
            "concurrent_write_source_events": source_events,
            "concurrent_write_attribution_paths": attr_paths,
            "later_write_source_event_before_response": source_events == 1,
            "later_write_inline_size_before_response": inline_size_before_response,
        },
    }
    raw = json.dumps(evidence, indent=2, sort_keys=True) + "\n"
    scrub_text(raw)
    return evidence, trace


def self_test():
    home = Path.home()
    try:
        assert_not_primary(home / ".lastdb" / "evidence.json")
    except MeasureError:
        return 0
    raise MeasureError("self-test did not refuse a LastDB home path")


def main():
    parser = argparse.ArgumentParser(description="Measure an isolated schema-root attribution copy.")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--trace", type=Path)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--lastdbd", default=shutil.which("lastdbd") or "lastdbd")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        self_test()
        print("self-test: PASS")
        return 0
    if args.out is None:
        raise MeasureError("--out is required")
    assert_not_primary(args.out)
    if args.trace:
        assert_not_primary(args.trace)
    work = args.work or Path("/tmp") / ("sra-measure-%s" % os.getpid())
    work.mkdir(parents=True, exist_ok=True)
    assert_not_primary(work)
    evidence, trace = measure(args.lastdbd, work)
    args.out.write_text(json.dumps(evidence, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if args.trace:
        args.trace.write_text(json.dumps(trace, indent=2, default=str) + "\n", encoding="utf-8")
    print(args.out)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MeasureError as exc:
        print("measure: %s" % exc, file=__import__("sys").stderr)
        raise SystemExit(1)
