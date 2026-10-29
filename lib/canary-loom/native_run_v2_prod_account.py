"""Read one published PROD request's reservations without account reconciliation.

Only keyed, consistent Dynamo DB reads and STS identity reads occur. Provider
byte/route facts come from the separately retained completed cloud restore.
"""

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import time

from native_upgrade_common import require
from native_run_v2_inputs import external, parent_descriptor, unique
from native_run_v2_auto_qualify_io import reference, save
from native_run_v2_auto_qualify_process import execute
from native_run_v2_prod_chain import accepted_point, decimal, digest, head, identifier, integer

AWS_ACCOUNT = "152335099025"
REGION = "us-east-1"
CONTROL = "ExememCloudControl-prod"
BILLING = "ExememBilling-prod"
COUNTERS = ("native_backup_reserved_bytes", "native_backup_retained_bytes", "native_backup_allocation_revision")
PROJECTION = ("--projection-expression", "account_id,record_id,#json,#revision",
              "--expression-attribute-names", '{"#json":"json","#revision":"revision"}')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode()


def framed(domain, value):
    domain, body = domain.encode(), canonical(value)
    value = len(domain).to_bytes(4, "big") + domain + len(body).to_bytes(8, "big") + body
    return hashlib.sha256(value).hexdigest()


def scope_prefix(scope):
    return "s#" + framed("lastdb:cloud-byte-backup:scope:v2", scope) + "#"


def fresh_output(path):
    path = external(path)
    parent = parent_descriptor(path)
    try:
        require(not os.path.lexists(path), "prod_account_fresh_output")
        os.mkdir(path.name, 0o700, dir_fd=parent)
        os.fsync(parent)
    finally:
        os.close(parent)
    return path


def environment():
    allowed = ("HOME", "PATH", "AWS_PROFILE", "AWS_DEFAULT_PROFILE", "AWS_ACCESS_KEY_ID",
               "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_SHARED_CREDENTIALS_FILE",
               "AWS_CONFIG_FILE", "AWS_WEB_IDENTITY_TOKEN_FILE", "AWS_ROLE_ARN", "AWS_ROLE_SESSION_NAME")
    result = {key: os.environ[key] for key in allowed if key in os.environ}
    result.update(AWS_PAGER="", AWS_CLI_AUTO_PROMPT="off", AWS_EC2_METADATA_DISABLED="true",
                  AWS_IGNORE_CONFIGURED_ENDPOINT_URLS="true", LC_ALL="C", LANG="C", TZ="UTC")
    return result


class Reads:
    def __init__(self, output, executable):
        self.output, self.executable = output, Path(executable).resolve(strict=True)
        info = self.executable.lstat()
        require(stat.S_ISREG(info.st_mode) and info.st_uid in (0, os.getuid())
                and not info.st_mode & 0o022 and os.access(self.executable, os.X_OK), "prod_account_aws_program")
        self.calls, self.originals, self.deadline = 0, [], time.monotonic() + 300
        self.environment = environment()

    def call(self, service, action, *arguments):
        require((service, action) in {("sts", "get-caller-identity"), ("dynamodb", "get-item"),
                                     ("dynamodb", "query")}, "prod_account_read_only_action")
        require(time.monotonic() < self.deadline, "prod_account_read_deadline")
        self.calls += 1
        require(self.calls <= 8192, "prod_account_request_bound")
        output = self.output / ("read-" + str(self.calls).zfill(5))
        command = [str(self.executable), "--region", REGION, "--endpoint-url",
                   f"https://{service}.{REGION}.amazonaws.com", "--no-cli-pager", "--no-paginate",
                   "--output", "json", service, action, *arguments]
        raw = execute(command, self.environment, output, timeout=min(35, self.deadline - time.monotonic()))
        value = json.loads(raw, object_pairs_hook=unique,
                           parse_constant=lambda unused: require(False, "prod_account_nonfinite_json"))
        require(time.monotonic() < self.deadline and isinstance(value, dict), "prod_account_read_response")
        self.originals.append({"service": service, "action": action,
                               "response": reference(output / "stdout.bin")})
        return value

    def item(self, partition, record):
        key = canonical({"account_id": {"S": partition}, "record_id": {"S": record}}).decode()
        result = self.call("dynamodb", "get-item", "--table-name", CONTROL, "--key", key,
                           "--consistent-read", *PROJECTION)
        return decoded_record(result.get("Item"), partition, record)

    def billing(self, account):
        key = canonical({"user_hash": {"S": account}}).decode()
        result = self.call("dynamodb", "get-item", "--table-name", BILLING, "--key", key,
                           "--consistent-read", "--projection-expression", "user_hash," + ",".join(COUNTERS))
        item = result.get("Item")
        require(isinstance(item, dict) and set(item) == {"user_hash", *COUNTERS}
                and item["user_hash"] == {"S": account}, "prod_account_explicit_billing_counters")
        values = {}
        for name in COUNTERS:
            require(isinstance(item[name], dict) and set(item[name]) == {"N"}, "prod_account_billing_number")
            values[name] = decimal(item[name]["N"])
        return values


def decoded_record(item, partition, record):
    require(isinstance(item, dict) and set(item) == {"account_id", "record_id", "json", "revision"}
            and item["account_id"] == {"S": partition} and item["record_id"] == {"S": record}
            and isinstance(item["json"], dict) and set(item["json"]) == {"S"}
            and isinstance(item["revision"], dict) and set(item["revision"]) == {"N"},
            "prod_account_exact_service_record")
    raw = item["json"]["S"]
    require(isinstance(raw, str) and 0 < len(raw.encode()) <= 256 * 1024, "prod_account_service_record_size")
    value = json.loads(raw, object_pairs_hook=unique,
                       parse_constant=lambda unused: require(False, "prod_account_nonfinite_record"))
    revision = decimal(item["revision"]["N"])
    require(isinstance(value, dict) and revision > 0, "prod_account_service_record_object_or_revision")
    return {"revision": revision, "value": value}


def publication(reads, partition, prefix, accepted):
    job = accepted["begin"]["job"]
    commit = job["commit_id"]
    saved = reads.item(partition, prefix + "job#" + commit)
    selected = reads.item(partition, prefix + "accepted#" + commit)
    value = saved["value"]
    result = value.get("result", {})
    require(selected["value"] == accepted and value.get("subject") == job["stream"]["scope"]["account_id"]
            and value.get("begin") == accepted["begin"]
            and integer(result.get("version")) == 2 and result.get("job") == job
            and result.get("begin_sha256") == framed("lastdb:cloud-byte-backup:begin:v2", accepted["begin"])
            and result.get("status") == {"state": "published", "backup": accepted}
            and value.get("ci_retirement") is None and value.get("metadata_uses_recorded") is not False,
            "prod_account_exact_published_request")
    return {"job_revision": saved["revision"], "accepted_revision": selected["revision"]}


def terminal_obligation(value, name, start, job):
    require(value.get("job") == job and isinstance(value.get("binding"), dict), "prod_account_obligation_job")
    if "transfer_sha256" in value:
        require(set(value) == {"job", "transfer_sha256", "binding", "reserved_bytes", "state"}
                and name == start + digest(value["transfer_sha256"]), "prod_account_object_obligation")
        amount = integer(value["reserved_bytes"])
        allowed_state = ({"state", "stored_bytes"}, {"state", "stored_bytes", "evidence"})
    else:
        required = {"job", "kind", "sha256", "binding", "bytes", "state"}
        require(required <= set(value) <= required | {"incarnation", "terminal_put"}
                and value["kind"] in ("page", "index"), "prod_account_metadata_obligation")
        prefix = start + "reference#" + value["kind"] + "#" + digest(value["sha256"])
        suffix = name.removeprefix(prefix)
        incarnation = value.get("incarnation")
        ending = "" if incarnation is None else "#allocation#" + identifier(incarnation)
        require(name.startswith(prefix) and re.fullmatch(r"(?:#target#[0-9a-f]{64})?" + re.escape(ending), suffix)
                and ("terminal_put" not in value or value["terminal_put"] is True and incarnation is not None),
                "prod_account_metadata_obligation_identity")
        amount = integer(value["bytes"])
        allowed_state = ({"state", "stored_bytes"},)
    state = value.get("state")
    require(amount > 0 and isinstance(state, dict) and set(state) in allowed_state
            and state.get("state") == "retained" and integer(state.get("stored_bytes")) == amount,
            "prod_account_nonterminal_or_unknown_obligation")
    return amount


def obligations(reads, partition, prefix, accepted):
    job = accepted["begin"]["job"]
    start = prefix + "job#" + job["commit_id"] + "#obligation#"
    maximum = decimal(accepted["inventory_root"]["object_count"]) + decimal(accepted["inventory_root"]["page_count"]) + 1
    previous, cursor, count, stored, pages = None, None, 0, 0, 0
    while True:
        values = canonical({":account": {"S": partition}, ":prefix": {"S": start}}).decode()
        arguments = ["--table-name", CONTROL, "--consistent-read", "--limit", "128",
                     "--key-condition-expression", "account_id = :account AND begins_with(record_id, :prefix)",
                     "--expression-attribute-values", values, *PROJECTION]
        if cursor is not None:
            arguments += ["--exclusive-start-key", canonical(cursor).decode()]
        result = reads.call("dynamodb", "query", *arguments)
        rows = result.get("Items", [])
        require(isinstance(rows, list) and len(rows) <= 128
                and integer(result.get("Count")) == integer(result.get("ScannedCount")) == len(rows),
                "prod_account_complete_query_page")
        pages += 1
        for item in rows:
            name = item.get("record_id", {}).get("S")
            require(isinstance(name, str) and name.startswith(start)
                    and (previous is None or name > previous), "prod_account_obligation_membership")
            value = decoded_record(item, partition, name)["value"]
            amount = terminal_obligation(value, name, start, job)
            count, stored, previous = count + 1, integer(stored + amount), name
            require(count <= maximum, "prod_account_unexpected_request_obligation_count")
        next_cursor = result.get("LastEvaluatedKey")
        if not next_cursor:
            break
        require(isinstance(next_cursor, dict) and set(next_cursor) == {"account_id", "record_id"}
                and next_cursor["account_id"] == {"S": partition}
                and next_cursor["record_id"] == {"S": previous}
                and next_cursor != cursor and pages <= maximum + 1, "prod_account_query_continuation")
        cursor = next_cursor
    return {"complete": True, "records": count, "pages": pages, "retained_bytes_observed": stored,
            "reserved_bytes": 0, "unknown_states": 0, "scope": "selected-request-obligations"}


def collect(accepted, output, aws_path):
    """Create one fresh private record; never require another device's reserves to be zero."""
    accepted = accepted_point(accepted)
    dependencies = accepted["begin"].get("recovery_dependencies")
    require(dependencies is None or isinstance(dependencies, list) and len(dependencies) <= 2
            and all(head(value) for value in dependencies), "prod_account_dependency_shapes")
    output = fresh_output(output)
    reads = Reads(output, aws_path)
    outcome = {"schema": "lastdb.prod-request-reservations.v1", "status": "failed",
               "environment": "prod", "source": "independent-keyed-service-read",
               "reservation_scope": "selected-request-obligations", "whole_account_reconciled": False,
               "provider_mutations": 0, "primary_access": False}
    try:
        require(reads.call("sts", "get-caller-identity").get("Account") == AWS_ACCOUNT, "prod_account_aws_identity")
        account = accepted["begin"]["job"]["stream"]["scope"]["account_id"]
        partition, prefix = "cb2#" + account, scope_prefix(accepted["begin"]["job"]["stream"]["scope"])
        before = reads.billing(account)
        first = publication(reads, partition, prefix, accepted)
        selected = obligations(reads, partition, prefix, accepted)
        last = publication(reads, partition, prefix, accepted)
        after = reads.billing(account)
        require(first == last and after["native_backup_allocation_revision"] >= before["native_backup_allocation_revision"],
                "prod_account_publication_or_revision_changed")
        outcome.update(status="passed", accepted_backup=accepted, reservations=0, obligations=selected,
                       billing_before=before, billing_after=after, billing_stable=before == after,
                       billing_is_observation_only=True, publication=last, checked_at=int(time.time()),
                       historical_allocations_reconciled=False, compatible_writer_floor_verified=False)
        return save(output / "verified.json", {**outcome, "reads": reads.originals})
    except BaseException as error:
        outcome["failure_class"] = type(error).__name__
        raise
    finally:
        save(output / "result.json", {**outcome, "reads": reads.originals})
