"""Use the frozen operational Source with one explicit ordinary DEV account."""
import copy
import re
import time

from automatic_source import (MAX_CHECKPOINTS, MAX_DECLARED_BYTES, Source as FrozenSource,
    OperationError, canonical_uuid, checkpoint_identity, public, released_publication, require)


class Source(FrozenSource):
    """Only the four frozen account-sensitive methods use the selected account."""

    def __init__(self, node, baseline, source, summary, account):
        require(isinstance(account, str) and re.fullmatch(r"[0-9a-f]{32}", account),
                "explicit_dev_account")
        super().__init__(node, baseline, source, summary)
        self.account = account

    def connect(self, key):
        value = self.cloud("connect", "--existing", "--env", "dev", "--api-key-stdin",
                           "--expected-user-hash", self.account, input_bytes=key)
        require(value["manual_backup_enabled"] and not value["automatic_backup_enabled"]
                and not value["registration_attempted"], "existing_dev_connection_only")

    def policy(self, value, snapshot=86400):
        policy = value["automatic_backup"]
        require(value["user_hash"] == self.account and value["automatic_backup_enabled"] is True
                and policy["enabled"] is True and policy["paused"] is None
                and policy["log_interval_seconds"] == 60
                and policy["snapshot_interval_seconds"] == snapshot, "automatic_dev_policy")
        require(value["blocked_reason"] is None, "automatic_backup_blocked")
        return policy

    def published(self, kind, previous=None, snapshot=86400, through=None):
        deadline = time.monotonic() + 900
        while time.monotonic() < deadline:
            value = self.cloud("status", checkpoint=(kind, through))
            policy = self.policy(value, snapshot)
            accepted = value.get("last_accepted_backup")
            if (released_publication(value, policy) and value["backup_kind"] == kind
                    and accepted["commit_sha256"] != previous
                    and (through is None or all(policy["last_backed_up_frontiers"][name] >= frontier
                         for name, frontier in through.items()))):
                request = accepted["begin"]["job"]["commit_id"]
                canonical_uuid(request)
                require(request.startswith("a17dbac2-") and request == value["request_id"],
                        "daemon_initiated_request")
                require(accepted["begin"]["job"]["stream"]["scope"]["account_id"] == self.account,
                        "accepted_dev_scope")
                self.node.health()
                require(time.monotonic() < deadline, "automatic_publication_deadline")
                self.publication_deadlines[accepted["commit_sha256"]] = deadline
                self.summary["frozen_backup_selection"] = {"kind": kind, "request_id": request,
                    "commit_sha256": public(accepted["commit_sha256"], r"[0-9a-f]{64}")}
                return copy.deepcopy(value)
            time.sleep(0.5)
        raise OperationError("automatic_publication_deadline")

    def observe_accepted(self, accepted):
        job = accepted["begin"]["job"]
        request = canonical_uuid(job["commit_id"])
        require(request.startswith("a17dbac2-"), "daemon_initiated_request")
        require(job["stream"]["scope"]["account_id"] == self.account, "accepted_dev_scope")
        if self.completed:
            first = next(iter(self.completed.values()))
            require(job["stream"] == first["begin"]["job"]["stream"], "one_owned_automatic_stream")
        if request in self.completed:
            require(checkpoint_identity(self.completed[request]) == checkpoint_identity(accepted),
                    "immutable_published_checkpoint")
        else:
            declared = int(accepted["inventory_root"]["stored_bytes"])
            require(declared > 0, "positive_checkpoint_bytes")
            self.completed[request] = copy.deepcopy(accepted)
            self.declared_bytes += declared
        require(len(self.completed) <= MAX_CHECKPOINTS and self.declared_bytes <= MAX_DECLARED_BYTES,
                "bounded_ci_cloud_work")
