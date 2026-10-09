"""Finite factory authority, exact witnesses, and bounded public effects.

The controller owns one reviewed Card. A failed read never replaces a retained
witness, source contract, install request, or execution identity.
"""
from __future__ import annotations

import concurrent.futures
import fcntl
import hashlib
import http.client
import json
import os
import re
import signal
import socket
import shutil
import stat
import subprocess
import tempfile
import threading
import time
import uuid
from datetime import datetime
from pathlib import Path

MAX_BYTES = 16 * 1024 * 1024
MAX_KEYS = 8192
SLUG = re.compile(r'[a-z0-9][a-z0-9_-]{0,255}\Z')
HEX = re.compile(r'[0-9a-f]{64}\Z')
OID = re.compile(r'[0-9a-f]{40}\Z')
EXEC_ID = re.compile(r'lx-[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\Z')
RFC3339 = re.compile(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-](?:[01][0-9]|2[0-3]):[0-5][0-9])\Z')
REQUIRED_KEYS = {
    'factory-scoped-dispatch-20261008', 'factory-guarded-closeout-20261008',
    'factory-canonical-active-counts-20261008', 'factory-repair-controller-20261009',
}
COUNT_CARD = 'factory-canonical-active-counts-20261008'
COUNT_PAPERCUT = 'papercut-loom-active-summary-counts-terminal-duplicate-memberships-20261008'
AUTHORITY = 'decision-2026-10-08-factory-repair-slot-and-bounded-proof'
DECISION_POLICY_PATH = Path(__file__).resolve().parents[1] / 'config/factory-reviewed-decision.json'
DECISION_POLICY_SHA = 'a06114ee93dda0abe23bf1703938ee529db0a6d47623e2376df8bc415ecb0a94'
CREATE_POLICY_SHA = 'bc8da6322450572647c2f396a2c52fa981dc5a78ca12945ea84683117848a517'
ARRAYS = ('tags', 'deps', 'surfaces')
SCALARS = ('slug', 'title', 'body', 'board', 'column', 'position', 'assignee',
           'created_at', 'created_by', 'updated_at', 'db', 'repo', 'base', 'kind',
           'block_status', 'block_reason', 'north_star', 'milestone', 'pr_url', 'branch')
ACTIVE = {'initializing', 'running', 'waiting'}
FEATURES = {'exact_card_selector': '--only-card', 'canonical_resume_fence': True,
            'immutable_execution_input': True, 'factory_proof_handoff': 'execution-receipt-no-card-write',
            'park_policy': 'defer-without-card-write',
            'definition_policy': 'compiled-reviewed-version-without-latest-fallback',
            'worktree_policy': 'portal-dev-original-factory-branch',
            'execution_view_json': 'show ID --json',
            'reviewed_named_decision_receipt': {'version': 1, 'file_flag': '--reviewed-decision-receipt',
                'sha_flag': '--reviewed-decision-sha256', 'input_field': 'factory_decision_receipt',
                'max_bytes': 65536, 'max_snapshot_bytes': 65536, 'sha_encoding': 'utf8-exact-bytes',
                'record_encoding': 'utf8-sorted-compact-json-no-newline',
                'native_route': 'owner-uid-mode0600-uds-hash-range-keys', 'no_card_write': True,
                'claim_authority': 'supplied-raw23-snapshot-sha-before-decision-read',
                'policy_file': 'release/factory-reviewed-decision.json'}}
COUNT_PREDECESSOR_SOURCE = '9ef47d6a7d98a7edf1c9cac78ed25b8429528143'
COUNT_PREDECESSOR_CONTRACT_SHA = 'dd36d5771909bc89a3a19a2296f5310877965f59e13591955e679a8bc4ca3500'
COUNT_DISPATCH_CONTRACT_SHA = 'e9e1eacecd19d0ba4481ad7369947bd08d55621c0242dd9b584fdaed23061c80'
# Tom's accepted test deletion is a Count source predecessor, not a dispatch upgrade.
COUNT_PREDECESSOR_CONTRACT_JSON = '''{
  "budget_recovery_source_sha256": "0f1840ca33218a0f50974c568464ea11c99a4727fa09d103b2ddda7bbf99126f",
  "cli_source_sha256": "e59d186806bed160f7ff47d84a4f6ad44e0b8a3622f252b0ea18d122951268f4",
  "contract": 1,
  "definition_version": "5",
  "features": {
    "canonical_resume_fence": true,
    "definition_policy": "compiled-reviewed-version-without-latest-fallback",
    "exact_card_selector": "--only-card",
    "execution_view_json": "show ID --json",
    "factory_proof_handoff": "execution-receipt-no-card-write",
    "immutable_execution_input": true,
    "park_policy": "defer-without-card-write",
    "reviewed_named_decision_receipt": {
      "claim_authority": "supplied-raw23-snapshot-sha-before-decision-read",
      "file_flag": "--reviewed-decision-receipt",
      "input_field": "factory_decision_receipt",
      "max_bytes": 65536,
      "max_snapshot_bytes": 65536,
      "native_route": "owner-uid-mode0600-uds-hash-range-keys",
      "no_card_write": true,
      "policy_file": "release/factory-reviewed-decision.json",
      "record_encoding": "utf8-sorted-compact-json-no-newline",
      "sha_encoding": "utf8-exact-bytes",
      "sha_flag": "--reviewed-decision-sha256",
      "version": 1
    },
    "worktree_policy": "portal-dev-original-factory-branch"
  },
  "files": {
    "definitions/land-card.json": "800726e0da4aca6b33b5d3110b66b3a89a13790f12c00bae83fcd89b4bd272b5",
    "release/factory-reviewed-decision.json": "a06114ee93dda0abe23bf1703938ee529db0a6d47623e2376df8bc415ecb0a94",
    "scripts/build-artifact.sh": "c953204b5eddbc619d4af22a572ae7df8bb9849492aff31b722f6535d0a56d32",
    "scripts/lastdb-candidate-freshness.py": "6bbaac7b36a0657815ddf849988d60e5b96ca409df49b3e7888d5319596fe18e",
    "scripts/loom-agent-lib.sh": "e1e8b4b187a5c38cf566c36c2d830dfcd133ed8f19ce2222f28ddc0715612fb8",
    "scripts/loom-canary-check-cutover.sh": "235cca484101917e938ff7e27c9361085b46206e2f5d4dc3e196ca1d99e0dd54",
    "scripts/loom-canary-check-fix.sh": "7becebec0988f6ae000cf380446c5192f99474a56aadbc1ed105e0aa89d3300e",
    "scripts/loom-canary-check-retry.sh": "686df27dae4965235e6db0611d16e80e851fd65835e15db6f86c8206a8f3bf2e",
    "scripts/loom-canary-collect.sh": "7eb1bd286e96011a8dbdf3fd59d13de54485b9d0c0aa6ea1b082c3c5703cee9d",
    "scripts/loom-canary-heal.sh": "86447f0699c7d093f99fb44b61a8d6d5bddb6d6fba2718048a66a52c30c55e83",
    "scripts/loom-canary-report.sh": "26979031bc3da373a1c8d10fa7a4cbc4c2277eb9e21d204c7a6a6adf761b348d",
    "scripts/loom-canary-retry-upgrade.sh": "1193feafc7877b9e2cf18bbea9fcb43375fb13a5349f3e589f9d94f0d65d3b32",
    "scripts/loom-canary-step.sh": "6082ea969314e11164c7ec113b57001e79bd647c3c8c33165f4bf7c2a5f4f93f",
    "scripts/loom-card-brief.sh": "1736a913b84b519bd2bdae3cea4c465f872e894a70d3ab9810517ade664a66cf",
    "scripts/loom-card-check-push.sh": "f831b857e3b2b533e576b697ea75f380602998b877de55c1f1139b39a423bc56",
    "scripts/loom-card-claim.sh": "f47f724737bfaa4f83b440ae6f884e7937659930e4e7733b382ae914667e9d8c",
    "scripts/loom-card-close.sh": "449e16005a0f82dabc2292f026b9173fdb54210d1dfe31d4b98ee13a2f7865c7",
    "scripts/loom-card-park.sh": "9471d700f85bf29c4087ba31d0912d9d688ddf79f99cf514b32b87885313b886",
    "scripts/loom-card-resume.sh": "d8eeb5822e8cb82099f893fa1fd687dd0f293f9a7e25a19f9cb4c087956a8161",
    "scripts/loom-card-review-lib.sh": "190cb91ca6c96e909aea2863f9116067fc710b2eab37e8164414c8bcc3267e3f",
    "scripts/loom-card-review.sh": "09e606fb4ff23f98dcd16350f441e2f5479e887f7cec3578cac2c3251344fd68",
    "scripts/loom-card-revise.sh": "16b1349557eb825fa8b7236869ec692b4066dc7edc5ab9b561c72462b3095ee7",
    "scripts/loom-card-wait-ci.sh": "679ca9521f6aeffaabd76b10be77a3356eff6f1aa053ceb8843eaec0e78ca504",
    "scripts/loom-check-merged.sh": "760649b1128c6a193202963ebcc7af9c1bcf310239505b736a48c65de51cecbb",
    "scripts/loom-check-pr.sh": "0d0b8745f713b73076d3d0266a851d148e70f9b334905bdf85eded2d47f7e779",
    "scripts/loom-close-out.sh": "4da2ec03247f9ce5a2d10a1161a919536511e7f448d977168e7c13ca02c42fe6",
    "scripts/loom-codex-session.py": "e7aaa376bf91919875893637ac108002c115000003616e6cc26afe41ca79e30d",
    "scripts/loom-dashboard.sh": "0086f9016525adc2eed07cffd2dff0d814b1fd484025fdc3e39398ce191dac1a",
    "scripts/loom-decompose.sh": "8fea383bf8dbd8cf0c77da2a5caeab24861a47b150ccd1befb32cd7749a77e47",
    "scripts/loom-deploy.sh": "d078922f3dd7e2eee662ee9419da52c188eabb36fc805c8dd2177dd9d5998c18",
    "scripts/loom-design-soak-ask.sh": "8db0a28e298c88068b36a3e9ddb8f1ed6f65c79c0a941e8dfae6428a25df5e1a",
    "scripts/loom-design-soak-draft.sh": "fe07d124b8f6313104259c9369861c1ff28feb76411aad1f4de54d85450d4330",
    "scripts/loom-design.sh": "03d46f03c183f62b3bd04cafce10368a2cd675623c291b932e7b5232f0881147",
    "scripts/loom-drive-north-star-portfolio.sh": "e05800238bd47997446cd37199d854af6149ecd3e346ec4cc2a31f83aee4a28f",
    "scripts/loom-execution-dashboard.sh": "9bd44edd4415f3b161c44c648b1080c373b77b9c0b55d9658f2c087405fe667e",
    "scripts/loom-factory-contract.py": "ef112ec59357f828ea8aff9fb8766437349d39b0a74b9f672df25fc3d60de755",
    "scripts/loom-factory-kickoff.sh": "c2ac251466affb5b28743979f4f598646b17b6ecfc9eed65d362847583475c80",
    "scripts/loom-factory-lib.sh": "a60dfdac7354c0a96c3419a8933820723b0a2c19bcb31ecc58eea6969d3716ac",
    "scripts/loom-gate-open.sh": "0698929bcc3c7c0b2f642d6ac2cfeb11813720025f98a20f4fbd1600955d7484",
    "scripts/loom-implement.sh": "65cbc1fdfe41f09958d6f6d2de5440304eeaff9483907446a7806c54b4b342f6",
    "scripts/loom-land-card-kickoff.sh": "50cdcd47f86a8aab49f1e573074fde81f8df96f09dce38ec7e8596a0e3d5708b",
    "scripts/loom-land-cr-normalize.sh": "a3f70a0fcb07abe5c3f8106ca682c98b57fd53a5d1184aafdda9e19cb890d928",
    "scripts/loom-live-release-receipt-step.sh": "9fd02e579ebfb38e5148c81b28d990fbbcfb7983888412dc9da69118cac6a106",
    "scripts/loom-merge.sh": "df1246b44e823314ddb2e56c3968280f208aa89a9fd469ac2fe02fe2f50a3f0e",
    "scripts/loom-mutation-dogfood.sh": "b79ce807b844d0fdd42bb5b2b0eb9657acf996548eb67ea869efdeb4333b9343",
    "scripts/loom-mutation-window.sh": "c90a11ce121c286d42b7c509dbdcb7fc8e0af2c723b8a75b93a6b37c7b775ac5",
    "scripts/loom-north-star-after-close.sh": "9b55ab0d0d7c155be18e2eadf79dcbaebd9b668b36ee68498fc929a01c482add",
    "scripts/loom-north-star-close-out.sh": "6a8beecc7b5dde43f583caa4fd878b68c5ca413e59fd800eb39326d0a7785d22",
    "scripts/loom-north-star-gate-open.sh": "464a742ffe3d841b6745882fb4e15f70bc0d6c9c5ec050eee80faa1b9d29b2d6",
    "scripts/loom-north-star-intake.sh": "502ff46e55cdf1122254909043ff64930abf08404cb64ccdc04266ebde23a2eb",
    "scripts/loom-north-star-plan.sh": "880604b5700524562a2f43a71658f36bba0ecbe88eb7ef803f944664c5c97d79",
    "scripts/loom-north-star-proof.sh": "e5c9e93a811a736d013aa3da70fdd50f08566b3815b5e74150a907bfe3429ed2",
    "scripts/loom-north-star-review.sh": "c0c6d7e94df6a035dadfe35981356a25a76f81a1b98aaf532edc69a4fde37aa4",
    "scripts/loom-north-star-select.sh": "873fbca14eaf04ee55ba875735c7408960b493d310dd2a92789d9998c8332a03",
    "scripts/loom-north-star-wait.sh": "b7105ec8f9581f8285c246457e0e867421941eb6f52764c53270e40eb4e95ef3",
    "scripts/loom-north-star-work-claim.sh": "90abde4b69d7d85852959b26e795e4a01433dccc701408f2a150fcee0ad0e69c",
    "scripts/loom-north-star-work-close.sh": "58c9733c38981d12e97dad325255fa29d703ff6f58bf0646a5f76540f60143e2",
    "scripts/loom-north-star-work-normalize.sh": "3448d8affde222607e5cdf080c881903ee50a732808889311dcbd0a34dc898f8",
    "scripts/loom-plan.sh": "f50edf9c1d14155e8fea491835436ea8072b27084dafe419f4613a8562e35c15",
    "scripts/loom-pr-lib.sh": "7239e0870a18a7bb9f23a972b4d7486c046ea3275c882c07f491cea375e35a3b",
    "scripts/loom-proof.sh": "9dbecea8cb4effb799bb3b9d803ff7949fa483b41e19c38c2587e792168b1aed",
    "scripts/loom-review.sh": "dac1d3cb17ff1d2a3649459ed46bdad0469a2c03ff876742a6c69973bccc59b3",
    "scripts/loom-reviewed-decision.py": "159c35cb1c687346e67936e7092fbd958a191bef955b97199c2fc0c221feb2d4",
    "scripts/loom-safe-upgrade-step.sh": "e0a4bce94a89d0d387ecc11bda9a02b64fa5c4203979551a6870b98f9161c8d5",
    "scripts/loom-ship-north-star-live-proof.sh": "8cc994b6edc7efbc8552322006ef102781ac80293e51d73cb687d579cabc59f7",
    "scripts/loom-ship-review.sh": "1de45b477795331984debc3c38a9a8a73d1ba033491e5e7d1abe205e7145cf2c",
    "scripts/loom-ship-soak-enabler.sh": "eb62680309e6358d8341b140c5b7c94d1e1b71f0e0405527f43f8df245538571",
    "scripts/loom-ship-soak-heal.sh": "03e458a27e5f10795282099dd83d9e3b76f71f1a2392a23ab0a64097ff03da1d",
    "scripts/loom-ship-soak-proof.sh": "0ace7dcab0538ef2e9695c7cbf8b934cc2469302624fc0be1e3615df21518364",
    "scripts/loom-ship-soak-report.sh": "bcdd3749cdff34209eb0e344f3baf06f56f953163feff2415b9301bbd2304415",
    "scripts/loom-ship-soak-start.sh": "7cb9dac52de5a0caa62a2663a4ab18dce1d3b6fd3b308f331fedfc4646940063",
    "scripts/loom-ship-soak-verify.sh": "7c66a71269072132be2e1d1a693b678fde5c8f5117f5d245946a2a7f73f9d411",
    "scripts/loom-wait-ci.sh": "c315e545528025ec1872a1210c45273e70277543f5a684f2d3ee0c380bb74e89",
    "scripts/loom-whats-wrong-closeout.sh": "7076041ad2e3175707d413b7e10280477be37e26f46f0aad501cdc819f62b292",
    "scripts/loom-whats-wrong-heal.sh": "66569537813867d7bcc4d3b97521c871f47f69ca3691deba1986d723f18e1c35",
    "scripts/loom-whats-wrong-list.sh": "40645f0a04d8693f6c91312609099ccae5e679dcc27c0eb68ddee5d7786c6158",
    "scripts/loom-why-classify.sh": "136705c8284172d57c8c78c582d45d5f4297050ad389e514f598fc26d2865d96",
    "scripts/loom-why-heal.sh": "d7b8b8104d4bb4ce795950ce58857d65d43a15cc65a6d49e4a50832da5467488",
    "scripts/loom-why-probe.sh": "19be2032ef35b75754d6f24b6cfc896579c9c39d0f669cd5939306f460e14805",
    "scripts/loom-why-report.sh": "ce1c49d4a81dc561153c24a38fdd3fa1d94d690db0da08e550147230f266b470"
  },
  "runner_source_sha256": "c403d5e354266d76649052d6dba747cfa1c04a487c23750f2a5b987d807de382",
  "supervisor_source_sha256": "059b57d33027b1abfbdeb1c91a9a4a6e1ccc5fce6a6fb7050213143cea04b1e8"
}
'''
RUNTIME_REQUIRED = {
    'lib/forge-token.sh',
    'lib/factory_repair.py', 'lib/factory_bootstrap.py', 'lib/closeout_evidence.py', 'lib/sanitize_structured_fields.py',
    'bin/host-track', 'bin/last-stack-factory-repair-contract', 'bin/last-stack-factory-repair-controller',
    'bin/last-stack-factory-repair-kanban-adapter', 'bin/last-stack-factory-repair-proof',
    'bin/last-stack-factory-repair-routine', 'bin/last-stack-factory-bootstrap-closeout', 'bin/last-stack-kanban-show-batch',
    'bin/last-stack-papercut-reconcile-finite', 'bin/last-stack-papercut-lifecycle-close',
    'bin/last-stack-card-closeout', 'bin/last-stack-board-closeout-sweep',
    'bin/last-stack-card-closeout-merge-probe', 'bin/last-stack-kanban-done-when-eval',
    'bin/last-stack-lastdb-retry', 'lib/lastdb-retry-schedule.sh',
    'bin/last-stack-legacy-residue-probe', 'bin/last-stack-shell-prelude',
    'bin/last-stack-worktree-reclaim', 'bin/last-stack-brain-append-heartbeat',
    'bin/last-stack-github-artifact-pull', 'bin/last-stack-papercut-queue',
    'bin/last-stack-kanban-file-pr', 'bin/last-stack-kanban-decision-check',
    'bin/last-stack-closeout-index', 'lib/factory_reconcile.py', 'lib/host-track-install-lock.sh',
    'config/factory-canonical-active-counts.md', 'config/factory-reviewed-decision.json', 'config/factory-create-only-contract.json', 'config/factory-bootstrap-closeout.json', 'routines/factory-repair.md',
    'routines/papercut-reconciler.md', 'config/routines-registry/last-stack-factory-repair.toml',
}
DEADLINE = None


class Refusal(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Refusal(message)


def version1(value):
    return type(value) is int and value == 1


def kickoff_key(key, card):
    return isinstance(key, str) and re.fullmatch(r'card-' + re.escape(card) + r'-[0-9]{8}T[0-9]{6}Z', key) is not None


def sha(data):
    return hashlib.sha256(data).hexdigest()


def encoded(value):
    return (json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False) + '\n').encode()


def strict_json(data):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, 'duplicate-json-field')
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=pairs)


def set_deadline(seconds=1050):
    global DEADLINE
    DEADLINE = time.monotonic() + seconds


def value_sha(value):
    return sha(encoded(value))


def compact_sha(value):
    return sha(json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode())


def regular_file(path, cap):
    fd = os.open(Path(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(fd)
        require(stat.S_ISREG(info.st_mode) and 0 <= info.st_size <= cap, 'bounded-regular-file: ' + str(path))
        return os.fdopen(fd, 'rb')
    except BaseException:
        os.close(fd); raise


def read_bytes(path, cap=MAX_BYTES):
    with regular_file(path, cap) as stream:
        data = stream.read(cap + 1)
    require(len(data) <= cap, 'file-byte-limit: ' + str(path))
    require(DEADLINE is None or time.monotonic() < DEADLINE, 'phase-deadline')
    return data


def read_json(path):
    try:
        return strict_json(read_bytes(path))
    except (OSError, ValueError) as error:
        raise Refusal('invalid-json-file: ' + str(path)) from error


def file_sha(path):
    cap = 256 * 1024 * 1024; digest = hashlib.sha256(); total = 0
    with regular_file(path, cap) as stream:
        while block := stream.read(1024 * 1024):
            total += len(block); require(total <= cap, 'runtime-file-byte-limit')
            require(DEADLINE is None or time.monotonic() < DEADLINE, 'phase-deadline')
            digest.update(block)
    return digest.hexdigest()


def relative_file(root, relative):
    require(isinstance(relative, str) and 0 < len(relative) <= 512, 'invalid-relative-path')
    rel = Path(relative)
    require(not rel.is_absolute() and '..' not in rel.parts and '.' not in rel.parts, 'escaping-relative-path')
    path = root / rel
    require(path.resolve().is_relative_to(root.resolve()), 'escaping-file-symlink')
    return path


def validate_manifest(config):
    require(isinstance(config, dict) and version1(config.get('version')), 'manifest-version')
    keys = config.get('protected_card_keys')
    require(isinstance(keys, list) and 1 <= len(keys) <= 16 and all(isinstance(k, str) and SLUG.fullmatch(k) for k in keys), 'protected-keys-shape')
    require(len(keys) == len(set(keys)) and REQUIRED_KEYS.issubset(keys), 'protected-keys-incomplete')
    admitted = config.get('admitted')
    require(isinstance(admitted, list) and len(admitted) <= 1, 'finite-admission-shape')
    for entry in admitted:
        require(isinstance(entry, dict) and entry.get('card') == COUNT_CARD and entry.get('papercut') == COUNT_PAPERCUT,
                'unknown-finite-admission')
        require(entry.get('repo') == 'EdgeVector/loom' and entry.get('base') == 'main', 'admission-repo-base')
        require(entry.get('proof_action') == 'canonical-active-counts-v1', 'unknown-proof-action')
        require(HEX.fullmatch(entry.get('brief_sha256', '')), 'reviewed-brief-sha')
        require(set(entry.get('surfaces', [])) == {'src/runner.rs', 'src/storage.rs', 'release/factory-dispatch-contract.json'}, 'admission-surfaces')
    return config


def validate_admitted_body(body, entry):
    require(isinstance(body, str), 'reviewed-brief-body')
    raw = read_bytes(DECISION_POLICY_PATH, 65536); require(sha(raw) == DECISION_POLICY_SHA, 'reviewed-decision-policy-drift')
    policy = strict_json(raw); decision = policy['decision']
    require(version1(policy.get('version')) and policy.get('card') == entry['card'] == COUNT_CARD and policy.get('repo') == entry['repo'] and
            policy.get('base') == entry['base'] and policy.get('authority_slug') == AUTHORITY and policy.get('brief_sha256') == entry['brief_sha256'] and
            sha(decision['body'].encode()) == policy['decision_body_sha256'] and compact_sha(decision) == policy['decision_record_sha256'], 'reviewed-decision-policy-identity')
    require(body.count('\n## DECISION-CHECK\n') == 1 and body.count('## DECISION-CHECK') == 1, 'reviewed-decision-stamp-count')
    prefix, stamp = body.split('\n## DECISION-CHECK\n'); lines = stamp.splitlines()
    require(len(lines) == 5 and re.fullmatch(r'date: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z', lines[0]) and
            lines[1:] == ['verdict: honor', 'slugs: ' + decision['slug'], 'store: brain', 'read: brain get ' + decision['slug']], 'reviewed-decision-clearance')
    require(sha(prefix.encode()) == entry['brief_sha256'], 'reviewed-brief-drift')
    receipt = {'version': 1, 'card': policy['card'], 'repo': policy['repo'], 'base': policy['base'], 'authority_slug': AUTHORITY,
        'brief_sha256': policy['brief_sha256'], 'card_body_sha256': sha(body.encode()),
        'decision_stamp': {'verdict': 'honor', 'store': 'brain', 'slugs': [decision['slug']]},
        'reads': [{'type': 'decision', 'schema_hash': policy['schema_hash'], **decision,
                   'body_sha256': policy['decision_body_sha256'], 'record_sha256': policy['decision_record_sha256'], 'constraints': policy['constraints']}]}
    receipt['receipt_sha256'] = compact_sha(receipt)
    return receipt


def validate_local(root, raw=None):
    root = Path(root).resolve()
    path = root / 'config/factory-repair-contract.json'
    raw = read_bytes(path) if raw is None else raw
    require(not has_conflict_markers(raw), 'contract-has-merge-conflict-markers')
    contract = strict_json(raw)
    require(version1(contract.get('version')), 'runtime-contract-version')
    require(contract.get('manifest_path') == 'config/factory-repair-slot.json', 'manifest-path')
    config_path = relative_file(root, contract['manifest_path'])
    require(file_sha(config_path) == contract.get('manifest_sha256'), 'manifest-digest-mismatch')
    config = validate_manifest(read_json(config_path))
    files = contract.get('runtime_files')
    require(isinstance(files, list) and 1 <= len(files) <= 512, 'runtime-file-list')
    seen = set()
    for entry in files:
        require(isinstance(entry, dict) and isinstance(entry.get('sha256'), str) and HEX.fullmatch(entry['sha256']), 'runtime-file-entry')
        relative = entry.get('path')
        require(relative != 'config/factory-repair-contract.json' and relative not in seen, 'runtime-file-duplicate-or-self')
        seen.add(relative)
        require(file_sha(relative_file(root, relative)) == entry['sha256'], 'runtime-file-mismatch: ' + relative)
    require(RUNTIME_REQUIRED.issubset(seen), 'runtime-dependencies-incomplete')
    present = set()
    with os.scandir(root / 'bin') as entries:
        for index, entry in enumerate(entries):
            require(index < 512, 'runtime-bin-count-limit')
            require(entry.is_file(), 'runtime-bin-entry-shape')
            present.add('bin/' + entry.name)
    require(present == {rel for rel in seen if rel.startswith('bin/') and len(Path(rel).parts) == 2}, 'runtime-unbound-bin-file')
    return {'version': 1, 'result': 'ok', 'contract_sha256': sha(raw),
            'manifest_sha256': contract['manifest_sha256'], 'protected_card_keys': config['protected_card_keys']}


CONFLICT_MARKER = re.compile(rb'^(?:<<<<<<<|>>>>>>>)(?:[ \t]|\r?$)', re.MULTILINE)


def has_conflict_markers(raw):
    return CONFLICT_MARKER.search(raw) is not None


def contract_shape(contract):
    # The checks that refresh_local needs before it touches a contract. Returns the runtime file entries.
    require(isinstance(contract, dict) and version1(contract.get('version')) and contract.get('manifest_path') == 'config/factory-repair-slot.json',
            'runtime-contract-shape')
    files = contract.get('runtime_files')
    require(isinstance(files, list) and 1 <= len(files) <= 512, 'runtime-file-list')
    known = set()
    for entry in files:
        require(isinstance(entry, dict) and isinstance(entry.get('path'), str), 'runtime-file-entry')
        require(entry['path'] != 'config/factory-repair-contract.json' and entry['path'] not in known, 'runtime-file-duplicate-or-self')
        known.add(entry['path'])
    return files


def contract_conflict_sides(raw):
    # The contract is one line, so two PRs that pinned different files leave exactly one conflict hunk over the whole file.
    # Returns (ours, theirs, base) as parsed contracts. base is None unless git wrote a diff3 base section. Anything else is a refusal.
    sections = {'ours': [], 'base': [], 'theirs': []}; state = 'start'; has_base = False
    for line in raw.splitlines(keepends=True):
        bare = line.rstrip(b'\r\n')
        if state == 'start':
            require(bare.startswith(b'<<<<<<<'), 'contract-conflict-unreadable: text before the first marker')
            state = 'ours'
        elif state == 'end':
            require(not bare.strip(), 'contract-conflict-unreadable: text after the last marker')
        elif bare.startswith(b'<<<<<<<') or (state == 'theirs' and (bare.startswith(b'|||||||') or bare.startswith(b'======='))):
            raise Refusal('contract-conflict-unreadable: more than one conflict hunk, or an extra marker')
        elif state == 'ours' and bare.startswith(b'|||||||'):
            state = 'base'; has_base = True
        elif state in ('ours', 'base') and bare.startswith(b'======='):
            state = 'theirs'
        elif state == 'theirs' and bare.startswith(b'>>>>>>>'):
            state = 'end'
        else:
            require(not bare.startswith(b'>>>>>>>') and not (state == 'base' and bare.startswith(b'|||||||')), 'contract-conflict-unreadable: markers out of order')
            sections[state].append(line)
    require(state == 'end', 'contract-conflict-unreadable: the conflict has no closing marker')
    sides = []
    for label in ('ours', 'theirs') + (('base',) if has_base else ()):
        try:
            side = strict_json(b''.join(sections[label])); contract_shape(side)
        except (ValueError, Refusal) as error:
            raise Refusal('contract-conflict-unreadable: the ' + label + ' side is not a contract: ' + str(error)) from error
        sides.append(side)
    return sides[0], sides[1], (sides[2] if has_base else None)


def resolve_conflicted_contract(raw):
    # Both sides pinned files; refresh_local recomputes every sha256 from the bytes in the tree, so the hashes need no merge.
    # The path set is the union of the two sides. A diff3 base lets a removal by either side stand. A field that is not a pin
    # must be equal on both sides, or the conflict is a real edit that this tool does not decide.
    ours, theirs, base = contract_conflict_sides(raw)
    for key in sorted((set(ours) | set(theirs)) - {'runtime_files', 'manifest_sha256'}):
        require(ours.get(key) == theirs.get(key), 'contract-conflict-field: ' + key + ' differs between the two sides')
    entries = {}
    for side in (ours, theirs):
        for entry in side['runtime_files']:
            entries.setdefault(entry['path'], entry)
    paths = [{entry['path'] for entry in side['runtime_files']} for side in (ours, theirs)]
    if base is None:
        keep = paths[0] | paths[1]
    else:
        was = {entry['path'] for entry in base['runtime_files']}
        keep = (paths[0] & paths[1]) | ((paths[0] | paths[1]) - was)
    contract = dict(ours); contract['runtime_files'] = [dict(entries[path]) for path in sorted(keep)]
    return contract


def refresh_local(root, add=()):
    # Re-pin the contract to the bytes in this checkout. Every bin/ or lib/ edit changes a pinned sha256 on the one
    # contract line, so by hand the edit is easy to forget (red main) and conflicts between concurrent PRs.
    # The path set is never narrowed. A new bin/ file needs --add. The result must pass validate_local before it is written.
    # A merge conflict in the contract is resolved here: the pins are rewritten from the bytes anyway (resolve_conflicted_contract).
    root = Path(root).resolve()
    require((root / '.git').exists(), 'refresh-needs-git-checkout: an install tree is not re-pinned')
    path = root / 'config/factory-repair-contract.json'
    raw = read_bytes(path); conflict = has_conflict_markers(raw)
    contract = resolve_conflicted_contract(raw) if conflict else strict_json(raw)
    files = contract_shape(contract)
    known = {entry['path'] for entry in files}
    added = []
    for relative in add:
        relative_file(root, relative)
        require(relative != 'config/factory-repair-contract.json', 'runtime-file-duplicate-or-self')
        if relative not in known:
            files.append({'path': relative, 'sha256': ''}); known.add(relative); added.append(relative)
    with os.scandir(root / 'bin') as entries:
        unbound = sorted('bin/' + entry.name for entry in entries if entry.is_file() and 'bin/' + entry.name not in known)
    require(not unbound, 'runtime-unbound-bin-file: ' + ', '.join(unbound) + ' (pin a new bin/ file with --add PATH)')
    files.sort(key=lambda entry: entry['path'])
    changed = []
    for entry in files:
        try:
            digest = file_sha(relative_file(root, entry['path']))
        except OSError as error:
            raise Refusal('runtime-file-missing: ' + entry['path']) from error
        if digest != entry.get('sha256'):
            entry['sha256'] = digest; changed.append(entry['path'])
    manifest = contract['manifest_path']; digest = file_sha(relative_file(root, manifest))
    if digest != contract.get('manifest_sha256'):
        contract['manifest_sha256'] = digest; changed.append(manifest)
    updated = encoded(contract)
    validate_local(root, raw=updated)
    if updated != raw:
        mode = stat.S_IMODE(path.stat().st_mode)
        atomic_json(path, contract); os.chmod(path, mode)
    return {'version': 1, 'result': 'refreshed' if updated != raw else 'current', 'changed': sorted(changed), 'added': added,
            'resolved_conflict': conflict, 'contract_sha256': sha(updated)}


def validate_snapshot(item, slug):
    require(isinstance(item, dict) and item.get('slug') == slug and item.get('missing') is not True, 'snapshot-key')
    text = item.get('snapshot_json'); expected = item.get('snapshot_sha256')
    require(isinstance(text, str) and len(text.encode()) <= 1024 * 1024, 'snapshot-bytes')
    require(isinstance(expected, str) and HEX.fullmatch(expected) and sha(text.encode()) == expected, 'snapshot-byte-sha')
    value = strict_json(text)
    require(set(value) == {'version', 'schema_hash', 'fields'} and version1(value['version']) and
            isinstance(value['schema_hash'], str) and HEX.fullmatch(value['schema_hash']), 'snapshot-shape')
    fields = value['fields']
    require(isinstance(fields, dict) and set(fields) == set(SCALARS + ARRAYS), 'raw23-field-set')
    require(all(isinstance(fields[key], str) for key in SCALARS), 'raw23-scalar-type')
    require(all(isinstance(fields[key], list) and all(isinstance(v, str) for v in fields[key]) for key in ARRAYS), 'raw23-array-type')
    require(fields['slug'] == slug, 'raw23-canonical-key')
    return {'slug': slug, 'fields': fields, 'text': text, 'sha256': expected, 'schema_hash': value['schema_hash']}


def synthetic_claim_reason(owner):
    return 'claim recovery pending for worker "' + owner + '": do not work this card until the claim completes'


def validate_claim_stage_one(previous_item, item, owner):
    slug = previous_item['slug']; before = validate_snapshot(previous_item, slug); after = validate_snapshot(item, slug)
    require(before['schema_hash'] == after['schema_hash'], 'claim-stage-one-schema-drift')
    previous = before['fields']; fields = after['fields']
    reason = synthetic_claim_reason(owner)
    require(previous['column'] == 'todo' and previous['assignee'] == '' and previous['block_status'] in ('', 'none') and previous['block_reason'] == '' or
            previous['column'] == 'doing' and previous['assignee'] == owner and previous['block_status'] == 'needs_human' and previous['block_reason'] == reason,
            'claim-stage-one-original-state')
    expected_tags = [v for v in previous['tags'] if not v.startswith(('done_at:', 'first_doing_at:'))]
    first = next((v[len('first_doing_at:'):] for v in previous['tags'] if v.startswith('first_doing_at:')), '')
    expected_tags.append('first_doing_at:' + (first or fields['updated_at']))
    require(fields['column'] == 'doing' and fields['assignee'] == owner and fields['block_status'] == 'needs_human' and fields['block_reason'] == reason and
            re.fullmatch(r'[0-9]{1,20}', fields['position']) and fields['tags'] == expected_tags and
            re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z', fields['updated_at']) and
            all(fields[k] == previous[k] for k in previous if k not in ('assignee', 'column', 'position', 'tags', 'block_status', 'block_reason', 'updated_at')),
            'claim-stage-one-field-drift')
    return fields


CLAIM_RECEIPT_KEYS = {'next_snapshot_json', 'next_snapshot_sha256', 'durability',
                      'guard_snapshot_sha256', 'contract_sha256', 'membership_cleanup'}

def claim_receipt_snapshot(previous, receipt, contract):
    require(isinstance(receipt, dict) and set(receipt) == CLAIM_RECEIPT_KEYS, 'claim-success-stage-shape')
    require(receipt.get('durability') == 'durable' and receipt.get('contract_sha256') == contract and
            receipt.get('guard_snapshot_sha256') == previous['snapshot_sha256'] and
            receipt.get('membership_cleanup') == 'deferred', 'claim-success-stage-authority')
    item = {'slug': previous['slug'], 'snapshot_json': receipt.get('next_snapshot_json'),
            'snapshot_sha256': receipt.get('next_snapshot_sha256')}
    require(validate_snapshot(previous, previous['slug'])['schema_hash'] == validate_snapshot(item, item['slug'])['schema_hash'],
            'claim-success-schema-drift')
    return item

def validate_claim_success(previous, receipt, owner, contract):
    require(isinstance(receipt, dict) and receipt.get('result') == 'claimed' and
            receipt.get('from') == 'todo' and receipt.get('to') == 'doing' and receipt.get('worker') == owner,
            'claim-success-result')
    fields = validate_snapshot(previous, previous['slug'])['fields']
    chain = receipt.get('claim_chain')
    if 'claim_chain' in receipt:
        require(isinstance(chain, dict) and set(chain) == {'version', 'mode', 'initial_snapshot_sha256', 'stages'} and
                version1(chain.get('version')) and chain.get('mode') == 'fresh' and
                chain.get('initial_snapshot_sha256') == previous['snapshot_sha256'] and
                isinstance(chain.get('stages'), list) and len(chain['stages']) == 2 and
                fields['column'] == 'todo' and fields['assignee'] == '' and fields['block_status'] in ('', 'none') and fields['block_reason'] == '',
                'claim-success-chain-shape')
        for stage, name in zip(chain['stages'], ('accepted-held', 'cleared')):
            require(isinstance(stage, dict) and set(stage) == {'stage', 'receipt'} and stage.get('stage') == name,
                    'claim-success-stage-shape')
        held = claim_receipt_snapshot(previous, chain['stages'][0]['receipt'], contract)
        validate_claim_stage_one(previous, held, owner)
        clear_receipt = chain['stages'][1]['receipt']
    else:
        require(fields['column'] == 'doing' and fields['assignee'] == owner and
                fields['block_status'] == 'needs_human' and fields['block_reason'] == synthetic_claim_reason(owner),
                'claim-success-resume-state')
        held = previous
        clear_receipt = {key: receipt.get(key) for key in CLAIM_RECEIPT_KEYS}
    cleared = claim_receipt_snapshot(held, clear_receipt, contract)
    require(all(receipt.get(key) == clear_receipt[key] for key in CLAIM_RECEIPT_KEYS), 'claim-success-final-receipt')
    before = validate_snapshot(held, held['slug'])['fields']; after = validate_snapshot(cleared, cleared['slug'])['fields']
    require(after['block_status'] == 'none' and after['block_reason'] == '' and
            re.fullmatch(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z', after['updated_at']) and
            all(after[key] == before[key] for key in before if key not in ('block_status', 'block_reason', 'updated_at')),
            'claim-success-clear-delta')
    return cleared

def validate_dispatch_claim(state, receipt, contract):
    previous = state['original_witness']
    if 'claim_chain' not in receipt and state.get('accepted_held'):
        accepted = state['accepted_held']
        require(isinstance(accepted, dict) and version1(accepted.get('version')) and accepted.get('stage') == 'accepted-held' and
                accepted.get('durability') == 'durable' and accepted.get('contract_sha256') == contract and
                accepted.get('guard_snapshot_sha256') == state['original_witness']['snapshot_sha256'], 'claim-success-retained-hold-authority')
        previous = {'slug': state['card'], 'snapshot_json': accepted.get('snapshot_json'),
                    'snapshot_sha256': accepted.get('snapshot_sha256')}
        validate_claim_stage_one(state['original_witness'], previous, state['owner'])
    return validate_claim_success(previous, receipt, state['owner'], contract)


def validate_card_batch(reply, keys):
    require(isinstance(reply, dict) and version1(reply.get('version')) and isinstance(reply.get('schema_hash'), str) and HEX.fullmatch(reply['schema_hash']), 'card-batch-shape')
    items = reply.get('items')
    require(isinstance(items, list) and len(items) == len(keys), 'card-batch-incomplete')
    for key, item in zip(keys, items):
        require(isinstance(item, dict) and item.get('slug') == key, 'card-batch-order-or-key')
        if item.get('missing') is True:
            require(set(item) == {'slug', 'missing'}, 'missing-item-shape')
        else:
            snapshot = validate_snapshot(item, key)
            require(snapshot['schema_hash'] == reply['schema_hash'], 'card-batch-schema-drift')
    return items


def bounded_call(argv, timeout=30, env=None, cap=MAX_BYTES, stdin=None):
    """Bound bytes, wall time and the generated client's process group."""
    require(0 < timeout <= 900, 'invalid-call-deadline')
    if DEADLINE is not None:
        timeout = min(timeout, DEADLINE - time.monotonic())
        require(timeout > 0, 'phase-deadline')
    require(stdin is None or isinstance(stdin, bytes) and len(stdin) <= 1024 * 1024, 'command-stdin-limit')
    with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err, tempfile.TemporaryFile() as inp:
        if stdin is not None:
            inp.write(stdin); inp.seek(0)
        proc = subprocess.Popen(argv, stdout=out, stderr=err, stdin=inp if stdin is not None else subprocess.DEVNULL,
                                env=env, start_new_session=True, close_fds=True)
        end = time.monotonic() + timeout
        try:
            while proc.poll() is None:
                if time.monotonic() >= end or os.fstat(out.fileno()).st_size > cap or os.fstat(err.fileno()).st_size > cap:
                    raise Refusal('bounded-command-timeout-or-bytes')
                time.sleep(0.02)
        finally:
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid, signal.SIGKILL); proc.wait(timeout=2)
        out.seek(0); err.seek(0)
        stdout = out.read(cap + 1); stderr = err.read(cap + 1)
        require(len(stdout) <= cap and len(stderr) <= cap, 'command-byte-limit')
        return proc.returncode, stdout, stderr


def json_call(argv, timeout=30, env=None, cap=MAX_BYTES):
    rc, out, err = bounded_call(argv, timeout, env, cap)
    require(rc == 0, 'public-command-refused: ' + Path(argv[0]).name)
    try:
        return strict_json(out)
    except ValueError as error:
        raise Refusal('public-command-malformed-json') from error


def public_card_batch(binary, keys, chunk=256):
    require(0 < chunk <= 256 and len(keys) <= MAX_KEYS and len(keys) == len(set(keys)), 'card-key-limit-or-duplicates')
    require(all(isinstance(k, str) and SLUG.fullmatch(k) for k in keys), 'invalid-card-key')
    parts = [keys[i:i + chunk] for i in range(0, len(keys), chunk)]
    def fetch(part):
        with tempfile.TemporaryDirectory(prefix='last-stack-card-keys-') as name:
            path = Path(name) / 'keys.json'; path.write_bytes(encoded(part))
            reply = json_call([str(binary), 'guarded-snapshot', '--slugs-file', str(path), '--json'], 30, cap=8 * 1024 * 1024)
            return reply['schema_hash'], validate_card_batch(reply, part)
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        replies = list(pool.map(fetch, parts))
    schemas = {reply[0] for reply in replies}
    require(len(schemas) <= 1, 'card-batch-schema-change')
    return {'version': 1, 'schema_hash': next(iter(schemas), ''),
            'items': [item for _, items in replies for item in items]}


def atomic_json(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, name = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(encoded(value)); stream.flush(); os.fsync(stream.fileno())
    os.replace(name, path)
    directory = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def artifact_root(authority):
    path = Path(authority['root']).expanduser().resolve()
    require(path.is_dir() and path.name == authority['manifest_sha256'], 'artifact-root-identity')
    return path


def verify_artifact(authority, current=False):
    root = artifact_root(authority)
    manifest_path = Path(authority['manifest_path']).expanduser()
    require(file_sha(manifest_path) == authority['manifest_file_sha256'], 'official-manifest-bytes-changed')
    manifest = read_json(manifest_path)
    require(manifest.get('manifest_digest') == authority['manifest_sha256'] and manifest.get('source_oid') == authority['source_oid'] and
            manifest.get('app') == authority['app'], 'official-artifact-identity')
    files = manifest.get('files')
    require(isinstance(files, list) and 1 <= len(files) <= 1024, 'official-artifact-files')
    seen = set()
    for item in files:
        rel = item.get('path'); require(rel not in seen, 'official-artifact-duplicate-file'); seen.add(rel)
        file = relative_file(root, rel)
        require(file.is_file() and file.stat().st_size == item.get('size') and file_sha(file) == item.get('sha256'), 'official-artifact-file-mismatch: ' + str(rel))
    if current:
        require(Path(authority['current']).expanduser().resolve() == root, 'installed-current-drift')
    return root


def verify_fk(authority, current=True, require_claim_chain=False):
    root = verify_artifact(authority, current)
    receipt = read_json(root / 'dist/guarded-contract.json')
    require(receipt.get('source_commit') == authority['source_oid'] and receipt.get('contract_sha256') == authority['contract_sha256'], 'fkanban-contract-identity')
    require(receipt.get('cli_sha256') == file_sha(root / 'dist/kanban') and receipt.get('mcp_sha256') == file_sha(root / 'dist/kanban-mcp'), 'fkanban-build-receipt')
    contract = receipt.get('contract', {})
    require(version1(contract.get('version')) and contract.get('snapshot_batch_shape') == 'ordered-items-with-explicit-missing' and
            contract.get('max_snapshot_keys') == 256 and contract.get('durability') == 'durable' and
            set(contract.get('card_fields', [])) == set(SCALARS + ARRAYS), 'fkanban-contract-capabilities')
    if require_claim_chain:
        require(contract.get('exact_claim_success_chain') == {
            'version': 1, 'field': 'claim_chain', 'mode': 'fresh', 'stages': ['accepted-held', 'cleared'],
            'guard_snapshot_sha256': 'per-stage-input', 'resume': 'single-clear-receipt'} and
            version1(contract['exact_claim_success_chain'].get('version')), 'fkanban-claim-chain-capability')
    return root / 'dist/kanban'


def verify_loom(authority, current=True):
    root = verify_artifact(authority, current)
    path = root / 'release/factory-dispatch-contract.json'; contract = read_json(path)
    require(file_sha(path) == authority['contract_sha256'] and contract.get('features') == FEATURES and contract.get('definition_version') == '5' and
            isinstance(contract.get('cli_source_sha256'), str) and HEX.fullmatch(contract['cli_source_sha256']) and
            contract.get('files', {}).get('release/factory-reviewed-decision.json') == DECISION_POLICY_SHA, 'loom-contract-identity')
    for rel, expected in contract.get('files', {}).items():
        require(file_sha(relative_file(root, rel)) == expected, 'loom-contract-file: ' + rel)
    build = read_json(root / 'release/factory-dispatch-build.json')
    require(build.get('contract_sha256') == authority['contract_sha256'] and build.get('runner_sha256') == file_sha(root / 'dist/loom'), 'loom-runner-binding')
    return root

def verify_creation_contract(root, config, binary):
    authority = config.get('creation_authority', {})
    require(authority.get('configured') is True, 'public-create-only-capability-unavailable')
    policy_path = Path(root) / 'config/factory-create-only-contract.json'
    require(file_sha(policy_path) == CREATE_POLICY_SHA, 'creation-policy-bytes')
    policy = read_json(policy_path)
    require(authority.get('contract_sha256') == policy.get('contract_sha256') and
            authority.get('card_guarded_contract_sha256') == config['fkanban_authority']['contract_sha256'], 'creation-config-contract-binding')
    current = json_call([str(binary), 'create-only-contract', '--json'], 30, cap=65536)
    require(isinstance(current, dict) and version1(current.get('version')) and current == policy and
            all(type(current.get(key)) is int for key in ('max_board_destinations', 'max_batch_operations', 'retries')) and
            current.get('force') is False and current.get('existing_board_required') is True and current.get('exact_card_schema_fields') is True,
            'creation-public-contract-binding')
    return authority

def validate_created_receipt(receipt, config):
    authority = config['creation_authority']
    require(isinstance(receipt, dict) and receipt.get('slug') == COUNT_CARD and receipt.get('action') == 'created' and
            receipt.get('board') == 'default' and receipt.get('column') == 'backlog' and receipt.get('durability') == 'durable' and
            receipt.get('contract_sha256') == authority['contract_sha256'] and
            receipt.get('card_guarded_contract_sha256') == config['fkanban_authority']['contract_sha256'] == authority['card_guarded_contract_sha256'] and
            receipt.get('absence_guard') == 'all23-absent' and receipt.get('membership_cleanup') == 'deferred', 'create-only-durable-receipt')
    item = {'slug': COUNT_CARD, 'snapshot_json': receipt.get('next_snapshot_json'), 'snapshot_sha256': receipt.get('next_snapshot_sha256')}
    fields = validate_snapshot(item, COUNT_CARD)['fields']
    require(fields['board'] == 'default' and fields['column'] == 'backlog' and fields['assignee'] == '' and
            fields['block_status'] in ('', 'none') and fields['block_reason'] == '' and fields['pr_url'] == '' and fields['branch'] == '', 'created-card-state')
    return item


def validate_execution(view, state):
    require(isinstance(view, dict) and view.get('id') == state['execution_id'] and view.get('idempotency_key') == state['key'], 'execution-identity')
    require(view.get('definition_name') == 'land-card' and view.get('definition_version') == '0000000005' and
            view.get('original_input') == state['original_input'], 'execution-original-input')
    original = state['original_input']; context = view.get('context')
    require(isinstance(context, dict) and original.get('factory_repair') is True, 'immutable-factory-mode')
    for key in ('factory_repair', 'factory_card', 'card', 'claim_worker', 'repo', 'base', 'factory_decision_receipt'):
        require(key in original and context.get(key) == original[key], 'execution-context-drift: ' + key)
    require(original['factory_decision_receipt'] == state['intent']['factory_decision_receipt'], 'execution-reviewed-decision-receipt')
    require(original['card'] == original['factory_card'] == state['card'] and original['claim_worker'] == state['owner'] and
            original['repo'] == state['repo'] and original['base'] == state['base'], 'execution-scope')
    require(view.get('corrected_reads', 0) == 0, 'canonical-read-below-accepted-ledger')
    return view


def accepted_handoff(view, state):
    validate_execution(view, state)
    require(view.get('status') == 'succeeded' and view.get('state') == 'DONE', 'execution-not-completed')
    nodes = [n for n in view.get('nodes', []) if n.get('node_id') == 'CLOSE_CARD']
    require(nodes, 'accepted-close-attempt-absent')
    latest = max(nodes, key=lambda n: n.get('attempt', -1))
    require(latest.get('status') == 'succeeded' and latest.get('pending_effect') is None, 'close-attempt-not-accepted')
    result = latest.get('result')
    require(isinstance(result, dict) and result.get('column') == 'factory-proof-handoff', 'close-handoff-result')
    handoff = result.get('handoff')
    require(isinstance(handoff, dict) and version1(handoff.get('contract')) and handoff.get('status') == 'awaiting-factory-proof' and
            handoff.get('no_card_write') is True and handoff.get('card_column') == 'doing', 'close-handoff-shape')
    for source, target in (('card', 'card'), ('owner', 'claim_worker'), ('repo', 'repo'), ('execution_id', 'execution_id'), ('key', 'idempotency_key')):
        require(handoff.get(target) == state[source], 'close-handoff-identity: ' + target)
    require(re.fullmatch(r'https://github.com/EdgeVector/loom/pull/[1-9][0-9]*', handoff.get('pr_url', '')), 'close-handoff-pr')
    return handoff


def compare_count(status, rows):
    require(isinstance(status, dict) and isinstance(status.get('executions'), list), 'status-result-shape')
    executions = status['executions']; keys = [r.get('id') for r in executions]
    require(len(keys) == len(set(keys)) and len(keys) <= MAX_KEYS, 'duplicate-active-execution')
    require(all(r.get('status') in ACTIVE for r in executions), 'terminal-or-parked-counted-active')
    canonical = {r.get('id'): r for r in rows}
    require(len(canonical) == len(rows) and set(keys).issubset(canonical), 'canonical-count-key-error')
    expected = [r for r in rows if r.get('status') in ACTIVE]
    require(set(keys) == {r['id'] for r in expected}, 'active-canonical-membership-mismatch')
    for row in executions:
        actual = canonical[row['id']]
        require(all(row.get(k) == actual.get(k) for k in ('status', 'state', 'updated_at', 'definition_name')), 'status-canonical-value-mismatch')
    by_status = {}; by_definition = {}
    for row in expected:
        by_status[row['status']] = by_status.get(row['status'], 0) + 1
        name = row['definition_name']; by_definition[name] = by_definition.get(name, 0) + 1
    require(type(status.get('total')) is int and status['total'] == len(expected) and status.get('by_status') == by_status and
            status.get('by_definition') == by_definition and all(type(value) is int for values in (status['by_status'], status['by_definition'])
            for value in values.values()), 'active-summary-count-mismatch')
    return {'total': len(expected), 'by_status': by_status, 'by_definition': by_definition,
            'candidate_source_limit': 'active IDs absent from all three named active status hashes are outside this read'}


class OwnerHTTP(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost', timeout=20); self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); self.sock.settimeout(self.timeout); self.sock.connect(self.path)


def owner_query_page(socket_path, schema, filter_value, fields, limit, offset=0):
    path = Path(socket_path).expanduser()
    info = path.stat()
    require(stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o600, 'owner-socket-identity')
    require(HEX.fullmatch(schema) and 0 < limit <= 1000, 'native-query-bounds')
    connection = OwnerHTTP(str(path))
    remaining = 20 if DEADLINE is None else min(20, DEADLINE - time.monotonic())
    require(remaining > 0, 'phase-deadline')
    connection.timeout = remaining
    connection.connect()
    # HTTPConnection can detach connection.sock when a response closes the
    # connection. Retain the actual wire through the bounded response drain.
    wire = connection.sock
    def expire():
        try:
            wire.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
    timer = threading.Timer(remaining, expire); timer.daemon = True; timer.start()
    response = None
    try:
        body = encoded({'schema_name': schema, 'filter': filter_value, 'fields': fields, 'limit': limit, 'offset': offset})
        connection.request('POST', '/api/query', body, {'Content-Type': 'application/json', 'X-LastDB-Client': 'last-stack-factory-proof'})
        response = connection.getresponse(); data = response.read(8 * 1024 * 1024 + 1)
        if DEADLINE is not None: require(time.monotonic() < DEADLINE, 'phase-deadline')
        require(response.status == 200 and len(data) <= 8 * 1024 * 1024, 'native-query-response')
        value = strict_json(data)
    finally:
        timer.cancel()
        if response is not None: response.close()
        connection.close(); wire.close()
    require(isinstance(value, dict) and value.get('ok') is True and isinstance(value.get('has_more'), bool) and isinstance(value.get('results'), list), 'native-query-incomplete')
    validate_native_metadata(value, 'native-query')
    require(value.get('next_cursor') is None, 'native-query-unexpected-cursor')
    require('returned_count' not in value or type(value['returned_count']) is int and value['returned_count'] == len(value['results']), 'native-query-returned-count')
    require(value.get('total_count') is None or type(value['total_count']) is int and value['total_count'] == len(value['results']), 'native-query-total-count')
    return value


def validate_native_metadata(value, scope, row=False):
    require(not value.get('error') and not value.get('errors'), scope + '-item-error')
    for key, count in value.items():
        if key == 'truncated':
            require(type(count) is bool and count is False, scope + '-truncated')
        elif re.search(r'skip|dangling|missing_atom|unresolved|failed|tombstoned', key, re.I):
            if row and key in ('skipped', 'dangling', 'missing_atom', 'unresolved', 'failed', 'tombstoned'):
                require(type(count) is bool and count is False, scope + '-record-flag: ' + key)
            else:
                require(type(count) is int and count == 0, scope + '-incomplete-counter: ' + key)


def require_lifecycle_intent_clear(directory, config_sha256, contract_sha256):
    path = Path(directory) / 'lifecycle-close-intent.json'
    if path.exists():
        try:
            raw = read_bytes(path)
            intent = strict_json(raw)
        except (OSError, ValueError) as error:
            raise Refusal('invalid-json-file: ' + str(path)) from error
        require(isinstance(intent, dict), 'lifecycle-close-unknown-retained')
        # The exact historical pass returned fixed=[], errors=[], and no Card
        # effect. Its complete receipt stays unchanged across this runtime
        # successor. Other predecessor receipts retain the unknown-write gate.
        reviewed_predecessor = sha(raw) == '55d438ce9b0429006af29297e8424c089f58db78e109d445f358114a38cecb29'
        current_authority = intent.get('config_sha256') == config_sha256 and intent.get('contract_sha256') == contract_sha256
        require(version1(intent.get('version')) and (current_authority or reviewed_predecessor) and intent.get('status') == 'complete' and
                isinstance(intent.get('result_sha256'), str) and HEX.fullmatch(intent['result_sha256']),
                'lifecycle-close-unknown-retained')


def owner_query(socket_path, schema, filter_value, fields, limit):
    value = owner_query_page(socket_path, schema, filter_value, fields, limit)
    require(value['has_more'] is False, 'native-keyed-query-truncated')
    return value['results']


def native_execution_rows(reply, keys):
    require(isinstance(reply, list) and len(reply) == len(keys), 'native-canonical-missing')
    wanted = set(keys); seen = set(); records = []
    for row in reply:
        require(isinstance(row, dict) and isinstance(row.get('key'), dict) and isinstance(row.get('fields'), dict), 'native-row-shape')
        validate_native_metadata(row, 'native-row', row=True)
        key = row['key']; fields = row['fields']; ident = key.get('hash')
        require(ident in wanted and ident not in seen and 'range' in key and key['range'] is None, 'native-row-foreign-duplicate-or-range')
        seen.add(ident)
        require(fields.get('id') == ident and all(isinstance(fields.get(k), str) and fields[k] for k in
                ('id', 'status', 'state', 'updated_at', 'definition_name')), 'native-canonical-field-shape')
        require(fields['status'] in ACTIVE | {'parked', 'succeeded', 'failed', 'cancelled'}, 'native-canonical-status')
        records.append(fields)
    require(seen == wanted, 'native-canonical-unresolved')
    return records


def status_membership_id(row, status_name):
    require(isinstance(row, dict) and isinstance(row.get('key'), dict) and
            row['key'].get('hash') == status_name and isinstance(row.get('fields'), dict),
            'native-membership-row-shape-or-hash')
    validate_native_metadata(row, 'native-membership', row=True)
    fields = row['fields']; ident = fields.get('id'); definition = fields.get('definition_name')
    sort = fields.get('by_status_sort')
    require(isinstance(ident, str) and EXEC_ID.fullmatch(ident), 'native-membership-id')
    require(isinstance(definition, str) and definition and isinstance(sort, str) and
            row['key'].get('range') == sort, 'native-membership-key')
    # Loom encodes created_at only in this range, not as a status-schema field.
    parts = sort.rsplit('#', 2)
    require(len(parts) == 3 and parts[0] == definition and parts[2] == ident,
            'native-membership-composite-key')
    created = parts[1]
    require(RFC3339.fullmatch(created), 'native-membership-created-at-format')
    try:
        datetime.fromisoformat(created.replace('Z', '+00:00'))
    except ValueError as error:
        raise Refusal('native-membership-created-at-value') from error
    return ident


def active_candidate_keys(config):
    hashes = read_json(Path(config['schema_map']).expanduser())
    require(hashes.get('LoomExecution') == config['loom_schemas']['LoomExecution'] and
            hashes.get('LoomExecutionByStatus') == config['loom_schemas']['LoomExecutionByStatus'], 'loom-schema-map-drift')
    def one(status_name):
        out = []; offset = 0
        for page in range(16):
            reply = owner_query_page(config['owner_socket'], hashes['LoomExecutionByStatus'], {'HashKey': status_name}, ['id', 'definition_name', 'by_status_sort'], 1000, offset)
            rows = reply['results']
            require(len(rows) <= 1000 and (rows or not reply['has_more']), 'native-membership-page')
            for row in rows:
                out.append(status_membership_id(row, status_name))
            if not reply['has_more']:
                return out
            offset += len(rows)
        raise Refusal('native-membership-page-limit')
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        result = list(pool.map(one, sorted(ACTIVE)))
    keys = sorted(set(k for part in result for k in part))
    require(len(keys) <= MAX_KEYS, 'native-candidate-key-limit')
    return keys


def canonical_execution_batch(config, keys):
    require(len(keys) <= MAX_KEYS and len(keys) == len(set(keys)), 'native-execution-key-limit')
    fields = ['id', 'definition_name', 'status', 'state', 'updated_at']
    def one(part):
        rows = owner_query(config['owner_socket'], config['loom_schemas']['LoomExecution'],
                           {'HashRangeKeys': [[k, ''] for k in part]}, fields, len(part))
        return native_execution_rows(rows, part)
    parts = [keys[i:i + 512] for i in range(0, len(keys), 512)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        rows = list(pool.map(one, parts))
    return [row for part in rows for row in part]


def validate_count_candidate_contract(source_raw, dispatch_raw, predecessor_source, predecessor_raw,
                                      merge_source, source_oid, tree_oid):
    """One fixed source predecessor; the actual dispatch receipt stays separate."""
    require(all(isinstance(raw, str) and len(raw.encode()) <= MAX_BYTES for raw in
                (source_raw, dispatch_raw, predecessor_raw)), 'candidate-contract-input')
    require(sha(dispatch_raw.encode()) == COUNT_DISPATCH_CONTRACT_SHA, 'candidate-dispatch-contract-bytes')
    require(predecessor_source == COUNT_PREDECESSOR_SOURCE, 'candidate-predecessor-source')
    require(sha(predecessor_raw.encode()) == COUNT_PREDECESSOR_CONTRACT_SHA, 'candidate-predecessor-contract-bytes')
    predecessor = strict_json(predecessor_raw); reviewed = strict_json(source_raw)
    require(isinstance(reviewed, dict) and version1(reviewed.get('contract')) and
            isinstance(reviewed.get('runner_source_sha256'), str) and HEX.fullmatch(reviewed['runner_source_sha256']) and
            reviewed['runner_source_sha256'] != predecessor['runner_source_sha256'], 'candidate-count-runner-delta')
    require(encoded(reviewed) == encoded({**predecessor, 'runner_source_sha256': reviewed['runner_source_sha256']}),
            'candidate-count-contract-delta')
    require(isinstance(merge_source, dict) and merge_source.get('sha') == source_oid and
            isinstance(merge_source.get('tree'), dict) and merge_source['tree'].get('sha') == tree_oid,
            'candidate-merge-source-tree')
    parents = merge_source.get('parents')
    require(isinstance(parents, list) and len(parents) == 1 and isinstance(parents[0], dict) and
            parents[0].get('sha') == COUNT_PREDECESSOR_SOURCE, 'candidate-merge-predecessor')
    return reviewed


class Controller:
    """One durable phase per wake; error leaves the retained phase and slot."""
    def __init__(self, config, state_dir, effects, contract_sha256):
        self.config = validate_manifest(config); self.directory = Path(state_dir)
        self.effects = effects; self.contract_sha256 = contract_sha256
        require(config.get('authority_slug') == AUTHORITY and len(config['admitted']) == 1, 'finite-authority')
        self.entry = config['admitted'][0]; self.config_sha256 = value_sha(config)

    def ensure_card(self, state, done=False, retained=False):
        require(not retained or done and state['phase'] == 'completed', 'retained-reader-terminal-only')
        current = self.effects.completed_card() if retained and hasattr(self.effects, 'completed_card') else self.effects.card()
        snapshot = validate_snapshot(current, state['card'])
        require(current['snapshot_sha256'] == state['witness']['snapshot_sha256'], 'retained-witness-changed')
        fields = snapshot['fields']
        require(fields['repo'] == state['repo'] and fields['base'] == state['base'] and
                set(fields['surfaces']) == set(self.entry['surfaces']), 'canonical-card-scope')
        if state['phase'] == 'claim-recovery-pending':
            require(fields['column'] == 'doing' and fields['assignee'] == state['owner'] and state.get('accepted_held'), 'accepted-held-canonical-owner')
            validate_claim_stage_one(state['original_witness'], current, state['owner'])
            return fields
        require(fields['block_status'] in ('', 'none') and fields['block_reason'] == '', 'canonical-human-hold')
        if done:
            require(fields['column'] == 'done' and fields['assignee'] == state['owner'], 'final-canonical-done')
        elif state['phase'] == 'reserved' or (state['phase'] == 'dispatch-pending' and not state.get('claim_receipt')):
            require(fields['column'] == 'todo' and fields['assignee'] == '', 'exact-card-not-ready')
        else:
            require(fields['column'] == 'doing' and fields['assignee'] == state['owner'], 'canonical-original-owner')
        return fields

    def save(self, state):
        atomic_json(self.directory / 'slot.json', state)

    def validate_state(self, state):
        require(version1(state.get('version')) and state.get('config_sha256') == self.config_sha256 and
                state.get('contract_sha256') == self.contract_sha256, 'slot-config-contract-drift')
        require(state.get('card') == self.entry['card'] and state.get('owner') == 'loom:factory-repair-slot' and
                state.get('repo') == self.entry['repo'] and state.get('base') == self.entry['base'], 'slot-identity')
        require(state.get('dispatch_authority') == self.config['dispatch_authority'] and
                state.get('fkanban_authority') == self.config['fkanban_authority'], 'slot-retained-authority')
        require(value_sha(state.get('intent')) == state.get('intent_sha256'), 'slot-intent-digest')
        require(validate_snapshot(state['original_witness'], state['card'])['sha256'] == state['intent']['witness_sha256'], 'slot-original-witness')
        decision = validate_admitted_body(validate_snapshot(state['original_witness'], state['card'])['fields']['body'], self.entry)
        require(state['intent'].get('factory_decision_receipt') == decision and
                strict_json(state['intent']['decision_receipt_json']) == decision and
                sha(state['intent']['decision_receipt_json'].encode()) == state['intent']['decision_receipt_sha256'], 'slot-retained-decision-receipt')
        require(all(state['intent'].get(k) == state[k] for k in ('card', 'owner', 'repo', 'base', 'config_sha256', 'contract_sha256')),
                'slot-intent-scope')

    def accept_write(self, state, receipt):
        require(isinstance(receipt, dict) and receipt.get('durability') == 'durable' and
                receipt.get('contract_sha256') == self.config['fkanban_authority']['contract_sha256'] and
                receipt.get('guard_snapshot_sha256') == state['witness']['snapshot_sha256'], 'guarded-write-not-durable')
        next_item = {'slug': state['card'], 'snapshot_json': receipt.get('next_snapshot_json'),
                     'snapshot_sha256': receipt.get('next_snapshot_sha256')}
        validate_snapshot(next_item, state['card'])
        state['witness'] = next_item
        state.setdefault('write_receipts', []).append(receipt)

    def validate_proof(self, state):
        proof = state.get('proof', {})
        require(version1(proof.get('version')) and proof.get('result') == 'positive' and proof.get('signal'), 'positive-proof-required')
        require(proof.get('signal') == value_sha({k: v for k, v in proof.items() if k != 'signal'}), 'proof-signal-digest')
        require(proof.get('intent_sha256') == state['intent_sha256'] and proof.get('card') == state['card'] and
                proof.get('execution_id') == state['execution_id'] and proof.get('action_attempt') == state['proof_attempt'] and
                proof.get('candidate_sha256') == value_sha(state['candidate']) and
                all(proof.get('candidate_' + k) == state['candidate'][k] for k in ('source_oid', 'contract_sha256', 'manifest_sha256')), 'proof-attempt-identity')

    def validate_install(self, state, receipt):
        self.validate_candidate(state)
        candidate = state['candidate']; requested = receipt.get('requested', {})
        require(version1(receipt.get('version')) and requested == {'app': 'loom', 'channel': 'candidate',
                'source_oid': candidate['source_oid'], 'manifest_sha256': candidate['manifest_sha256']}, 'install-request-drift')
        official = receipt.get('official', {})
        expected_official = {
            'repo': state['repo'], 'channel': 'candidate', 'platform': candidate['official']['platform'],
            'source_oid': candidate['source_oid'], 'tree_oid': candidate['tree_oid'],
            'manifest_sha256': candidate['manifest_sha256'], 'run_id': candidate['official']['run_id'],
            'artifact_id': candidate['official']['artifact_id']}
        require(isinstance(official, dict) and official == expected_official and
            all(type(official.get(k)) is int and official[k] > 0 for k in ('run_id', 'artifact_id')), 'install-official-drift')
        soak = receipt.get('soak', {})
        require(isinstance(soak, dict) and type(soak.get('required')) is bool, 'install-soak-shape')
        if receipt.get('result') == 'pending':
            require(receipt.get('exact_match') is False and receipt.get('installed') is None and
                    soak == {'required': True, 'status': 'pending'}, 'install-pending-shape')
            return False
        require(receipt.get('result') == 'installed' and receipt.get('exact_match') is True, 'exact-install-not-complete')
        require(soak.get('status') == 'complete', 'install-soak-not-complete')
        installed = receipt.get('installed', {})
        expected_files = [{k: row[k] for k in ('path', 'sha256')} for row in strict_json(candidate['manifest_json'])['files']]
        require(isinstance(installed, dict) and installed.get('source_oid') == candidate['source_oid'] and
                installed.get('tree_oid') == candidate['tree_oid'] and installed.get('manifest_sha256') == candidate['manifest_sha256'] and
                installed.get('resolved_root') == str(Path(candidate['authority']['root']).expanduser()) and
                installed.get('files') == expected_files, 'installed-source-tree-files-drift')
        return True

    def validate_candidate(self, state):
        candidate = state['candidate']
        require(candidate.get('intent_sha256') == state['intent_sha256'] and
                candidate.get('dispatch_authority_sha256') == value_sha(state['dispatch_authority']) and
                candidate.get('completed_execution_sha256') == state['completed_execution_sha256'] and
                candidate.get('pr_url') == state['handoff']['pr_url'], 'candidate-dispatch-chain')
        require(OID.fullmatch(candidate.get('source_oid', '')) and OID.fullmatch(candidate.get('tree_oid', '')) and
                HEX.fullmatch(candidate.get('manifest_sha256', '')) and HEX.fullmatch(candidate.get('contract_sha256', '')), 'candidate-exact-identity')
        pr = candidate.get('merge_receipt', {})
        require(isinstance(pr, dict) and pr.get('url') == state['handoff']['pr_url'] and pr.get('state') == 'MERGED' and
                isinstance(pr.get('mergedAt'), str) and pr['mergedAt'] and pr.get('baseRefName') == state['base'] and
                pr.get('headRefName') == 'factory/' + state['execution_id'] + '#IMPLEMENT' and
                pr.get('mergeCommit', {}).get('oid') == candidate['source_oid'], 'candidate-merged-pr-binding')
        require(isinstance(pr.get('body'), str) and re.search(r'(?m)^Papercut:[ \t]*' + re.escape(COUNT_PAPERCUT) + r'[ \t]*$', pr['body']) and
                re.search(r'(?m)^Keep-open:[ \t]*papercut-loom-execution-status-backlog-sweep-pending-20260928[ \t]*$', pr['body']), 'candidate-labeled-claims')
        official = candidate.get('official', {})
        require(isinstance(official, dict) and official.get('status') in ('promoted', 'verified') and
                official.get('oid') == candidate['source_oid'] and official.get('tree_oid') == candidate['tree_oid'] and
                official.get('manifest_digest') == candidate['manifest_sha256'] and official.get('channel') == 'candidate' and
                isinstance(official.get('platform'), str) and re.fullmatch(r'[a-z0-9_-]{1,64}', official['platform']) and
                all(type(official.get(k)) is int and official[k] > 0 for k in ('run_id', 'artifact_id')), 'candidate-official-publish-binding')
        raw = candidate.get('source_contract_json'); baseline_raw = candidate.get('baseline_contract_json'); manifest_raw = candidate.get('manifest_json')
        require(all(isinstance(text, str) and len(text.encode()) <= MAX_BYTES for text in (raw, baseline_raw, manifest_raw)) and
                sha(raw.encode()) == candidate['contract_sha256'] and
                sha(baseline_raw.encode()) == state['dispatch_authority']['contract_sha256'], 'candidate-retained-contract-bytes')
        reviewed = validate_count_candidate_contract(raw, baseline_raw, candidate.get('count_predecessor_source_oid'),
            candidate.get('count_predecessor_contract_json'), candidate.get('merge_source_receipt'),
            candidate['source_oid'], candidate['tree_oid'])
        manifest = strict_json(manifest_raw)
        require(isinstance(manifest, dict) and manifest.get('source_oid') == candidate['source_oid'] and
                manifest.get('app') == 'loom' and manifest.get('manifest_digest') == candidate['manifest_sha256'], 'candidate-manifest-source-binding')
        files = manifest.get('files'); require(isinstance(files, list) and 1 <= len(files) <= 1024, 'candidate-manifest-files')
        indexed = {}
        for row in files:
            require(isinstance(row, dict) and isinstance(row.get('path'), str) and row['path'] not in indexed and
                    not Path(row['path']).is_absolute() and '..' not in Path(row['path']).parts and
                    isinstance(row.get('sha256'), str) and HEX.fullmatch(row['sha256']) and
                    type(row.get('size')) is int and row['size'] >= 0, 'candidate-manifest-file-shape')
            indexed[row['path']] = row
        require(indexed.get('release/factory-dispatch-contract.json', {}).get('sha256') == candidate['contract_sha256'] and
                all(indexed.get(rel, {}).get('sha256') == expected for rel, expected in reviewed['files'].items()), 'candidate-manifest-contract-files')
        expected_authority = {'app': 'loom', 'source_oid': candidate['source_oid'], 'manifest_sha256': candidate['manifest_sha256'],
            'manifest_file_sha256': sha(manifest_raw.encode()), 'contract_sha256': candidate['contract_sha256'],
            'root': str(Path.home() / '.host-track/apps/loom/versions' / candidate['manifest_sha256']),
            'current': str(Path.home() / '.host-track/apps/loom/current'),
            'manifest_path': str(Path.home() / '.lastgit/artifacts/manifests' / (candidate['manifest_sha256'] + '.json'))}
        require(candidate.get('authority') == expected_authority, 'candidate-authority-path-binding')

    def completion(self, state):
        result = {k: state[k] for k in ('intent_sha256', 'config_sha256', 'contract_sha256', 'card', 'owner', 'execution_id', 'key', 'proof_attempt')}
        result.update(candidate_sha256=value_sha(state['candidate']), proof_sha256=value_sha(state['proof']),
                      install_sha256=value_sha(state['install']), close_sha256=value_sha(state['close_receipt']),
                      final_snapshot_sha256=state['witness']['snapshot_sha256'],
                      original_input_sha256=value_sha(state['original_input']),
                      handoff_sha256=value_sha(state['handoff']), completed_execution_sha256=state['completed_execution_sha256'])
        return result

    def once(self):
        self.directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.directory / 'slot.lock').open('a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return {'version': 1, 'result': 'noop', 'reason': 'shared-slot-busy'}
            path = self.directory / 'slot.json'
            if not path.exists():
                require_lifecycle_intent_clear(self.directory, self.config_sha256, self.contract_sha256)
                self.effects.check_authority()
                self.effects.bootstrap_ready()
                witness = self.effects.card(); value = validate_snapshot(witness, self.entry['card'])['fields']
                require(value['column'] == 'todo' and value['assignee'] == '' and value['block_status'] in ('', 'none') and
                        value['block_reason'] == '' and value['repo'] == self.entry['repo'] and value['base'] == self.entry['base'] and
                        set(value['surfaces']) == set(self.entry['surfaces']), 'finite-card-not-ready')
                decision = validate_admitted_body(value['body'], self.entry); decision_json = encoded(decision).decode()
                intent = {'card': self.entry['card'], 'owner': 'loom:factory-repair-slot', 'repo': self.entry['repo'],
                          'base': self.entry['base'], 'config_sha256': self.config_sha256,
                          'contract_sha256': self.contract_sha256, 'witness_sha256': witness['snapshot_sha256'],
                          'attempt': uuid.uuid4().hex, 'factory_decision_receipt': decision,
                          'decision_receipt_json': decision_json, 'decision_receipt_sha256': sha(decision_json.encode())}
                state = {'version': 1, 'phase': 'reserved', **{k: intent[k] for k in ('card', 'owner', 'repo', 'base', 'config_sha256', 'contract_sha256')},
                         'intent': intent, 'intent_sha256': value_sha(intent), 'witness': witness, 'original_witness': witness,
                         'dispatch_authority': self.config['dispatch_authority'], 'fkanban_authority': self.config['fkanban_authority']}
                self.save(state)
                return {'version': 1, 'result': 'ok', 'phase': 'reserved', 'card': state['card']}
            state = read_json(path); self.validate_state(state)
            phase = state['phase']
            if phase == 'completed':
                self.validate_proof(state)
                require(self.validate_install(state, state['install']), 'completion-install-pending')
                require(state.get('close_receipt', {}).get('durability') == 'durable' and
                        state.get('final_snapshot_sha256') == state['witness']['snapshot_sha256'] and
                        state.get('completion') == self.completion(state) and
                        state.get('completion_sha256') == value_sha(state['completion']), 'completion-receipt-invalid')
                self.ensure_card(state, done=True, retained=True)
                return {'version': 1, 'result': 'noop', 'phase': 'completed', 'card': state['card']}
            require_lifecycle_intent_clear(self.directory, self.config_sha256, self.contract_sha256)
            self.effects.check_authority(state)
            if phase == 'dispatch-pending' and hasattr(self.effects, 'recover_dispatch'):
                recovered = self.effects.recover_dispatch(state)
                if recovered:
                    state.update(recovered); self.save(state); phase = state['phase']
            self.ensure_card(state, done=phase == 'done-readback')
            if phase == 'reserved':
                # Persist attempted dispatch before the first public claim. Unknown
                # effect recovery reads this attempt; it never creates a new intent.
                state['phase'] = 'dispatch-pending'; self.save(state)
                update = self.effects.dispatch(state)
                state.update(update); self.save(state)
                if state.get('execution_id'):
                    validate_execution(self.effects.execution(state), state)
                    state['phase'] = 'execution'; self.save(state)
            elif phase == 'dispatch-pending':
                state.update(self.effects.dispatch(state))
                self.save(state)
                if state.get('execution_id'):
                    validate_execution(self.effects.execution(state), state)
                    state['phase'] = 'execution'; self.save(state)
            elif phase == 'claim-recovery-pending':
                state.update(self.effects.resume_claim(state)); state['phase'] = 'dispatch-pending'; self.save(state)
            elif phase == 'execution':
                view = self.effects.execution(state); validate_execution(view, state)
                if view.get('status') != 'succeeded':
                    return {'version': 1, 'result': 'noop', 'phase': phase, 'reason': 'execution-retained', 'card': state['card']}
                state['handoff'] = accepted_handoff(view, state)
                state['completed_execution_sha256'] = value_sha(view)
                state['phase'] = 'candidate'; self.save(state)
            elif phase == 'candidate':
                state['candidate'] = self.effects.candidate(state)
                self.validate_candidate(state)
                state['phase'] = 'install'; self.save(state)
            elif phase == 'install':
                receipt = self.effects.install(state)
                if not self.validate_install(state, receipt):
                    return {'version': 1, 'result': 'noop', 'phase': phase, 'reason': 'official-soak-pending', 'card': state['card']}
                state['install'] = receipt; state['proof_attempt'] = uuid.uuid4().hex
                state['phase'] = 'proof'; self.save(state)
            elif phase == 'proof':
                state['proof'] = self.effects.prove(state); self.validate_proof(state)
                state['phase'] = 'proof-mark'; self.save(state)
            elif phase == 'proof-mark':
                require(self.validate_install(state, state['install']), 'proof-install-not-complete')
                self.validate_proof(state)
                self.accept_write(state, self.effects.write(state, 'proof-mark'))
                state['phase'] = 'pr-metadata'; self.save(state)
            elif phase == 'pr-metadata':
                require(self.validate_install(state, state['install']), 'proof-install-not-complete')
                self.validate_proof(state)
                fields = self.ensure_card(state)
                evidence = self.effects.parse(fields, state['handoff']['pr_url'])
                require(evidence.get('verdict') == 'positive' and evidence.get('signal') and not evidence.get('reopened_same_signal'), 'latest-positive-evidence-required')
                require(not evidence.get('done_when'), 'card-prose-done-when-deferred')
                state['accepted_evidence'] = evidence
                self.accept_write(state, self.effects.write(state, 'pr-metadata'))
                state['phase'] = 'close'; self.save(state)
            elif phase == 'close':
                require(self.validate_install(state, state['install']), 'proof-install-not-complete')
                self.validate_proof(state)
                fields = self.ensure_card(state)
                evidence = self.effects.parse(fields, state['handoff']['pr_url'])
                require(evidence.get('verdict') == 'positive' and evidence.get('signal') == state['accepted_evidence']['signal'] and
                        not evidence.get('done_when') and not evidence.get('reopened_same_signal'), 'close-latest-evidence-drift')
                receipt = self.effects.write(state, 'close'); self.accept_write(state, receipt)
                state['close_receipt'] = receipt; state['phase'] = 'done-readback'; self.save(state)
            elif phase == 'done-readback':
                self.ensure_card(state, done=True)
                state['completion'] = self.completion(state)
                state['completion_sha256'] = value_sha(state['completion']); state['final_snapshot_sha256'] = state['witness']['snapshot_sha256']
                state['phase'] = 'completed'; self.save(state)
            else:
                raise Refusal('unknown-retained-phase')
            return {'version': 1, 'result': 'ok', 'phase': state['phase'], 'card': state['card']}


class Runtime:
    def __init__(self, root, config, directory):
        self.root = Path(root); self.config = config; self.directory = Path(directory)
        self.fk = config['fkanban_authority']; self.baseline = config['dispatch_authority']

    def check_authority(self, state=None):
        self.kanban = verify_fk(self.fk, require_claim_chain=True)
        if state is None or state['phase'] in ('reserved', 'dispatch-pending', 'claim-recovery-pending', 'execution', 'candidate', 'install'):
            self.loom = verify_loom(self.baseline, current=state is None or state['phase'] in ('reserved', 'dispatch-pending', 'claim-recovery-pending', 'execution', 'candidate'))
        else:
            self.loom = verify_loom(state['candidate']['authority'])

    def card(self):
        return self.read_card(current=True)

    def completed_card(self):
        return self.read_card(current=False)

    def read_card(self, current):
        self.kanban = verify_fk(self.fk, current=current, require_claim_chain=True)
        item = public_card_batch(self.kanban, [COUNT_CARD])['items'][0]
        require(item.get('missing') is not True, 'finite-card-missing')
        return item

    def bootstrap_ready(self):
        from factory_bootstrap import require_bootstraps_complete
        local = validate_local(self.root)
        require_bootstraps_complete(self.root, self.directory, local['contract_sha256'], self.kanban)

    def dispatch(self, state):
        logs = self.directory / 'kickoff'; logs.mkdir(exist_ok=True, mode=0o700)
        intent = {**state, 'receipt_path': str(self.directory / ('claim-' + state['intent']['attempt'] + '.json'))}
        atomic_json(self.directory / 'dispatch-intent.json', intent)
        current = logs / 'factory-repair-slot.current'
        if not current.exists():
            require(not Path(intent['receipt_path']).exists(), 'claim-without-observed-execution-retained')
            call_path = self.directory / ('dispatch-call-' + state['intent']['attempt'] + '.json')
            require(not call_path.exists(), 'dispatch-call-unknown-retained')
            env = dict(os.environ)
            for key in tuple(env):
                if key.startswith('LOOM_') or key == 'KANBAN_BIN':
                    del env[key]
            env.update(LOOM_BIN=str(self.loom / 'dist/loom'), LOOM_SCRIPTS=str(self.loom / 'scripts'), LOOM_DEFS=str(self.loom / 'definitions'),
                       KANBAN_BIN=str(self.root / 'bin/last-stack-factory-repair-kanban-adapter'),
                       LOOM_KICKOFF_LOG_ROOT=str(logs), LOOM_KICKOFF_WORKER='factory-repair-slot',
                       LAST_STACK_FACTORY_INTENT=str(self.directory / 'dispatch-intent.json'))
            decision_path = self.directory / ('reviewed-decision-' + state['intent']['decision_receipt_sha256'] + '.json')
            if not decision_path.exists(): decision_path.write_bytes(state['intent']['decision_receipt_json'].encode())
            require(file_sha(decision_path) == state['intent']['decision_receipt_sha256'], 'dispatch-decision-file-drift')
            atomic_json(call_path, {'version': 1, 'intent_sha256': state['intent_sha256'], 'card': state['card'],
                'decision_receipt_sha256': state['intent']['decision_receipt_sha256'], 'status': 'attempted'})
            rc, out, err = bounded_call([str(self.loom / 'scripts/loom-land-card-kickoff.sh'), '--only-card', state['card'],
                '--reviewed-decision-receipt', str(decision_path), '--reviewed-decision-sha256', state['intent']['decision_receipt_sha256']], 180, env)
            (self.directory / 'kickoff.out').write_bytes(out); (self.directory / 'kickoff.err').write_bytes(err)
            require(rc == 0 and current.exists(), 'exact-kickoff-no-observed-execution')
        parts = read_bytes(current, 1024 * 1024).decode().strip().split(' ', 3)
        require(len(parts) == 4 and parts[1] == state['card'] and kickoff_key(parts[0], state['card']), 'kickoff-current-identity')
        key, _, pid, raw_input = parts
        require(pid.isdigit(), 'kickoff-current-pid')
        log = logs / (key + '.log')
        lines = read_bytes(log, 8 * 1024 * 1024).decode().splitlines() if log.exists() else []
        ids = [line for line in lines if EXEC_ID.fullmatch(line)]
        require(len(set(ids)) <= 1, 'kickoff-execution-ambiguous')
        receipt = read_json(intent['receipt_path'])
        witness = validate_dispatch_claim(state, receipt, self.fk['contract_sha256'])
        return {'execution_id': ids[-1] if ids else '', 'key': key, 'original_input': strict_json(raw_input), 'witness': witness, 'claim_receipt': receipt}

    def recover_dispatch(self, state):
        path = self.directory / ('claim-' + state['intent']['attempt'] + '.json')
        if not path.exists():
            return None
        receipt = read_json(path)
        if receipt.get('result') == 'claimed':
            witness = validate_dispatch_claim(state, receipt, self.fk['contract_sha256'])
            return {'witness': witness, 'claim_receipt': receipt}
        require(receipt.get('code') == 'claim_recovery_pending', 'unknown-claim-recovery-receipt')
        accepted = receipt.get('accepted_held', {})
        require(version1(accepted.get('version')) and accepted.get('stage') == 'accepted-held' and accepted.get('durability') == 'durable' and
                accepted.get('contract_sha256') == self.fk['contract_sha256'] and
                accepted.get('guard_snapshot_sha256') == state['intent']['witness_sha256'], 'accepted-held-recovery-authority')
        witness = {'slug': state['card'], 'snapshot_json': accepted.get('snapshot_json'), 'snapshot_sha256': accepted.get('snapshot_sha256')}
        validate_claim_stage_one(state['original_witness'], witness, state['owner'])
        return {'witness': witness, 'accepted_held': accepted, 'phase': 'claim-recovery-pending'}

    def resume_claim(self, state):
        # This only clears the exact accepted synthetic stage through public FK.
        # It never drives or invents a missing execution/current identity.
        intent = {**state, 'receipt_path': str(self.directory / ('claim-' + state['intent']['attempt'] + '.json'))}
        path = self.directory / 'dispatch-intent.json'; atomic_json(path, intent)
        env = dict(os.environ); env['LAST_STACK_FACTORY_INTENT'] = str(path)
        receipt = json_call([str(self.root / 'bin/last-stack-factory-repair-kanban-adapter'), 'pickup', 'claim-v2',
                             '--only-card', state['card'], '--worker', state['owner'], '--json'], 90, env)
        require(receipt.get('result') == 'claimed' and receipt.get('durability') == 'durable' and
                receipt.get('contract_sha256') == self.fk['contract_sha256'] and
                receipt.get('guard_snapshot_sha256') == state['witness']['snapshot_sha256'], 'accepted-held-clear-not-durable')
        witness = {'slug': state['card'], 'snapshot_json': receipt['next_snapshot_json'], 'snapshot_sha256': receipt['next_snapshot_sha256']}
        validate_snapshot(witness, state['card'])
        return {'witness': witness, 'claim_receipt': receipt}

    def execution(self, state):
        return json_call([str(self.loom / 'dist/loom'), 'show', state['execution_id'], '--json'], 30)

    def candidate(self, state):
        gh = shutil.which('gh', path=str(Path.home() / '.local/bin') + os.pathsep + os.environ.get('PATH', ''))
        require(gh is not None, 'installed-github-cli-unavailable')
        pr = json_call([gh, 'pr', 'view', state['handoff']['pr_url'], '-R', state['repo'], '--json',
                        'state,mergedAt,mergeCommit,baseRefName,headRefName,body,url'], 30)
        require(pr.get('url') == state['handoff']['pr_url'] and pr.get('state') == 'MERGED' and pr.get('mergedAt') and pr.get('baseRefName') == state['base'] and
                pr.get('headRefName') == 'factory/' + state['execution_id'] + '#IMPLEMENT', 'merged-pr-execution-binding')
        oid = pr.get('mergeCommit', {}).get('oid', '')
        require(OID.fullmatch(oid), 'merged-source-oid')
        require(re.search(r'(?m)^Papercut:\s*' + re.escape(COUNT_PAPERCUT) + r'\s*$', pr.get('body', '')) and
                re.search(r'(?m)^Keep-open:\s*papercut-loom-execution-status-backlog-sweep-pending-20260928\s*$', pr.get('body', '')), 'merged-pr-labeled-claim')
        content = json_call([gh, 'api', 'repos/' + state['repo'] + '/contents/release/factory-dispatch-contract.json?ref=' + oid], 30)
        import base64
        raw = base64.b64decode(content.get('content', ''), validate=False); reviewed = strict_json(raw)
        baseline_raw = read_bytes(self.loom / 'release/factory-dispatch-contract.json').decode()
        merge_source = json_call([gh, 'api', 'repos/' + state['repo'] + '/git/commits/' + oid], 30)
        tree_oid = merge_source.get('tree', {}).get('sha', '') if isinstance(merge_source, dict) and isinstance(merge_source.get('tree'), dict) else ''
        require(isinstance(tree_oid, str) and OID.fullmatch(tree_oid), 'candidate-merge-tree-oid')
        reviewed = validate_count_candidate_contract(raw.decode(), baseline_raw, COUNT_PREDECESSOR_SOURCE,
            COUNT_PREDECESSOR_CONTRACT_JSON, merge_source, oid, tree_oid)
        pull = json_call([str(self.root / 'bin/last-stack-github-artifact-pull'), '--app', 'loom', '--repo', state['repo'],
                          '--branch', state['base'], '--oid', oid, '--channel', 'candidate', '--json'], 180)
        require(pull.get('status') in ('promoted', 'verified') and pull.get('oid') == oid and
                pull.get('tree_oid') == tree_oid and type(pull.get('artifact_id')) is int and pull['artifact_id'] > 0 and type(pull.get('run_id')) is int and pull['run_id'] > 0, 'candidate-official-publish-receipt')
        digest = pull.get('manifest_digest', ''); require(HEX.fullmatch(digest), 'candidate-manifest-digest')
        manifest_path = Path.home() / '.lastgit/artifacts/manifests' / (digest + '.json'); manifest = read_json(manifest_path)
        require(manifest.get('source_oid') == oid and manifest.get('manifest_digest') == digest and manifest.get('app') == 'loom', 'candidate-manifest-source')
        indexed = {item['path']: item for item in manifest['files']}
        require(indexed.get('release/factory-dispatch-contract.json', {}).get('sha256') == sha(raw), 'candidate-source-contract-not-in-artifact')
        for rel, expected in reviewed['files'].items():
            require(indexed.get(rel, {}).get('sha256') == expected, 'candidate-official-source-file: ' + rel)
        authority = {'app': 'loom', 'source_oid': oid, 'manifest_sha256': digest, 'manifest_file_sha256': file_sha(manifest_path),
                     'manifest_path': str(manifest_path), 'contract_sha256': sha(raw),
                     'root': str(Path.home() / '.host-track/apps/loom/versions' / digest),
                     'current': str(Path.home() / '.host-track/apps/loom/current')}
        return {'source_oid': oid, 'tree_oid': pull['tree_oid'], 'manifest_sha256': digest, 'contract_sha256': sha(raw),
                'manifest_json': read_bytes(manifest_path).decode(), 'source_contract_json': raw.decode(),
                'baseline_contract_json': baseline_raw, 'merge_receipt': pr, 'merge_source_receipt': merge_source,
                'count_predecessor_source_oid': COUNT_PREDECESSOR_SOURCE,
                'count_predecessor_contract_json': COUNT_PREDECESSOR_CONTRACT_JSON,
                'official': pull, 'authority': authority, 'dispatch_authority_sha256': value_sha(state['dispatch_authority']),
                'completed_execution_sha256': state['completed_execution_sha256'], 'intent_sha256': state['intent_sha256'], 'pr_url': state['handoff']['pr_url']}

    def install(self, state):
        candidate = state['candidate']
        rc, out, err = bounded_call([str(self.root / 'bin/host-track'), 'install', '--channel', 'candidate',
                                    '--expected-oid', candidate['source_oid'], '--expected-manifest', candidate['manifest_sha256'], '--json', 'loom'], 900)
        require(rc in (0, 75), 'official-exact-install-refused')
        receipt = strict_json(out)
        require((rc == 75) == (receipt.get('result') == 'pending'), 'installer-exit-receipt-mismatch')
        return receipt

    def prove(self, state):
        path = self.directory / ('proof-input-' + state['proof_attempt'] + '.json'); atomic_json(path, state)
        return json_call([str(self.root / 'bin/last-stack-factory-repair-proof'), '--state', str(path), '--json'], 180)

    def write(self, state, operation):
        witness = validate_snapshot(state['witness'], state['card'])
        path = self.directory / ('witness-' + witness['sha256'] + '.json')
        if not path.exists():
            path.write_text(witness['text'], encoding='utf-8')
        require(file_sha(path) == witness['sha256'], 'retained-witness-file')
        if operation == 'proof-mark':
            args = ['mark', state['card'], 'PROOF: END STATE met PASS factory-action=' + state['proof_attempt'] + ' signal=' + state['proof']['signal']]
        elif operation == 'pr-metadata':
            args = ['set', state['card'], '--pr-url', state['handoff']['pr_url'], '--branch', 'factory/' + state['execution_id'] + '#IMPLEMENT']
        elif operation == 'close':
            args = ['move', state['card'], 'done', '--from', 'doing']
        else:
            raise Refusal('unknown-guarded-operation')
        return json_call([str(self.kanban), *args, '--guard-snapshot', str(path), '--snapshot-sha256', witness['sha256'],
                          '--expect-assignee', state['owner'], '--json'], 60)

    def parse(self, card, pr):
        from closeout_evidence import parse_card_evidence
        return parse_card_evidence(card, pr)


def require_report_ready(directory, routine):
    path = Path(directory) / ('routine-closeout-' + routine + '.json')
    if path.exists():
        value = read_json(path)
        require(version1(value.get('version')) and value.get('status') == 'complete', 'routine-closeout-unknown-retained')


def routine_heartbeat(root, routine, result):
    outcome = 'ok' if result['result'] == 'ok' else ('noop' if result['result'] == 'noop' else 'error')
    detail = re.sub(r'[^a-zA-Z0-9_.-]', '-', str(result.get('phase', result.get('reason', 'retained'))))[:160]
    rc, out, err = bounded_call([str(Path(root) / 'bin/last-stack-brain-append-heartbeat'), '--automation', routine,
                               '--line', 'outcome=' + outcome + ' detail=' + detail], 10)
    require(rc == 0, 'routine-heartbeat-unavailable')


def routine_report(root, routine, result):
    """Report before the trailer. Unknown write receipts retain the report intent."""
    if result.get('result') == 'noop' and result.get('phase') == 'completed':
        return result
    import datetime as dt
    root = Path(root); directory = Path.home() / '.local/state/last-stack/factory-repair-slot'
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    path = directory / ('routine-closeout-' + routine + '.json')
    try:
        require_report_ready(directory, routine)
    except Refusal:
        return {**result, 'result': 'error', 'reason': 'routine-closeout-unknown-retained'}
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d-%H%M%S')
    slug = 'closeout-' + stamp + '-' + routine
    phase = re.sub(r'[^a-z0-9-]', '-', str(result.get('phase', 'unavailable')).lower())[:48]
    reason = str(result.get('reason', 'none'))
    friction = result.get('result') == 'error' and any(token in reason for token in
        ('timeout', 'public-command-', 'native-query-', 'malformed-json', 'unavailable', 'filing-attempt-unknown'))
    paper = 'papercut-factory-runtime-' + routine + '-' + phase + '-' + re.sub(r'[^a-z0-9-]', '-', reason.split(':', 1)[0].lower())[:64]
    brain = str(Path.home() / '.local/bin/brain')
    body = ('---\ntype: reference\nslug: ' + slug + '\ntitle: ' + routine + ' finite repair report\n---\n'
            'The routine result is ' + result['result'] + '. The slot keeps its retained authority and witness.\n'
            'Result metadata:\n\n```json\n' + json.dumps(result, sort_keys=True) + '\n```\n\n'
            'Friction: ' + (paper if friction else 'none; this pass adds no distinct tool failure claim') + '.\n').encode()
    atomic_json(path, {'version': 1, 'status': 'pending', 'slug': slug, 'report_sha256': sha(body), 'result_sha256': value_sha(result)})
    try:
        jobs = [(lambda: bounded_call([brain, 'put', slug, '--type', 'reference'], 30, stdin=body))]
        if friction:
            hits = json_call([brain, 'search', paper, '--type', 'papercut', '--limit', '5', '--json'], 30)
            require(isinstance(hits, list), 'runtime-friction-search-unavailable')
            exact = [hit for hit in hits if isinstance(hit, dict) and hit.get('slug') == paper]
            # Search is a sample. The known slug receives an exact existence read.
            rc, raw, err = bounded_call([brain, 'get', paper, '--type', 'papercut', '--json'], 30)
            remedy = strict_json(raw)
            absent = rc != 0 and isinstance(remedy, dict) and remedy.get('error') == 'No papercut: ' + paper
            require(rc == 0 or absent, 'runtime-friction-remedy-unavailable')
            evidence = 'Phase: ' + phase + '\nError: ' + reason + '\nRoutine: ' + routine + '\nThe slot stays occupied. No read failure proves absence.\n'
            if not absent:
                require(remedy.get('slug') == paper and remedy.get('status') == 'open', 'runtime-friction-remedy-requires-review')
                jobs.append(lambda: bounded_call([brain, 'append', paper, '--type', 'papercut'], 30, stdin=evidence.encode()))
            else:
                jobs.append(lambda: bounded_call([brain, 'papercut', 'file', paper, '--component', 'factory-repair',
                    '--severity', 'p1', '--title', 'Finite factory runtime cannot confirm ' + phase,
                    '--symptom', reason[:240], '--body', evidence], 30))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            receipts = list(pool.map(lambda job: job(), jobs))
        require(all(rc == 0 for rc, out, err in receipts), 'routine-brain-write-receipt-unknown')
        record = json_call([brain, 'get', slug, '--type', 'reference', '--json'], 30)
        require(record.get('slug') == slug and isinstance(record.get('body'), str) and
                json.dumps(result, sort_keys=True) in record['body'], 'routine-report-readback-unavailable')
        rc, out, err = bounded_call([str(root / 'bin/last-stack-closeout-index'), 'record', routine, slug], 30)
        require(rc == 0, 'routine-closeout-index-unknown')
        rc, out, err = bounded_call([str(root / 'bin/last-stack-closeout-index'), 'latest', routine], 30)
        require(rc == 0 and out.decode().strip() == slug, 'routine-closeout-index-readback-unavailable')
        atomic_json(path, {'version': 1, 'status': 'complete', 'slug': slug, 'report_sha256': sha(body), 'result_sha256': value_sha(result)})
        return {**result, 'closeout_slug': slug, 'friction_slug': paper if friction else None}
    except (Refusal, OSError, ValueError, KeyError, TypeError):
        return {**result, 'result': 'error', 'reason': 'routine-closeout-unknown-retained', 'closeout_slug': slug}
