#!/usr/bin/env python3
"""Durable, DEV-only cleanup of the exact stream a stopped restore proof made.

The proof enqueues after verification. The routines gate retries after read holds
and other scope work finish. AWS CLI and LastSecrets credentials stay in memory;
requests and resumable plans contain only identifiers, revisions and hashes.
"""
import argparse
import concurrent.futures
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import tomllib
import uuid
from datetime import datetime, timezone

API = "https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com"
REGION = "us-west-2"
TABLE = "ExememCloudControl-dev"
BILLING = "ExememBilling-dev"
AWS_ACCOUNT = "152335099025"
LIVE = "99f4351a-e59f-438f-8783-3a1888dd3b18"
CI_ACCOUNT = "2a81c95623f2445854a794b5b48471d6"
ROUTINE = "lastdb-dev-proof-cleanup"
MAX_ROWS = 10000
DELIVERY_DEADLINE = None


class DeliveryYield(Exception):
    """Leave a saved phase for the next bounded mechanical delivery."""


def require(condition, reason):
    if not condition:
        raise RuntimeError(reason)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def encoded(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def queue_root():
    return Path.home() / ".local/state/last-stack/lastdb-safe-upgrade/dev-stream-cleanup"


def private(path, limit=2_000_000):
    info = path.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o600 and info.st_size <= limit, "unsafe private file")
    return path.read_bytes()


def save(path, value, exclusive=False):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(not path.parent.is_symlink() and path.parent.stat().st_uid == os.getuid(), "unsafe request directory")
    os.chmod(path.parent, 0o700)
    data = encoded(value)
    if exclusive:
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        sync_directory(path.parent)
        return
    require(not path.is_symlink(), "unsafe state path")
    descriptor, temporary = tempfile.mkstemp(prefix=".cleanup-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def sync_directory(path):
    descriptor=os.open(path,os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def worker_ready():
    require(shutil.which("aws") and shutil.which("lastsecrets"), "AWS CLI or LastSecrets unavailable")
    registry = Path(os.environ.get("ROUTINES_HOME", str(Path.home()/".routines"))) / "registry" / (ROUTINE+".toml")
    require(registry.is_file() and not registry.is_symlink(), "cleanup routine is not installed")
    info = registry.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(), "unsafe cleanup routine")
    entry = tomllib.loads(registry.read_text())
    gate = str(Path.home()/".last-stack/bin/last-stack-dev-proof-cleanup")
    require(entry.get("status") == "active" and entry.get("gate_command") == gate
            and entry.get("id") == ROUTINE and entry.get("rrule") == "FREQ=MINUTELY;INTERVAL=10;BYSECOND=0"
            and os.access(gate, os.X_OK), "cleanup routine is not active with the installed gate")


def request_read(path):
    require(path.parent.resolve() == queue_root().resolve() and re.fullmatch(r"[0-9a-f-]{36}\.json", path.name), "request outside cleanup queue")
    raw = private(path)
    value = json.loads(raw)
    require(value["schema"] == "lastdb.dev-proof-cleanup.v1" and value["environment"] == "dev" and value["api_url"] == API, "cleanup environment mismatch")
    require(re.fullmatch(r"[0-9a-f]{32}", value["account_id"]) and value["account_id"] != CI_ACCOUNT, "protected cleanup account")
    for name in ("stream_id", "commit_id", "source_home"):
        require(str(uuid.UUID(value[name])) == value[name], "invalid proof identifier")
    require(value["stream_id"] != LIVE and path.stem == value["stream_id"], "protected stream or mismatched request")
    require(re.fullmatch(r"[0-9a-f]{64}", value["commit_sha256"]) and re.fullmatch(r"[0-9a-f]{64}", value["restore_report_sha256"]), "invalid proof digest")
    require(value["account_generation"].isdigit() and value["source_strict_stop"] and value["restored_strict_stop"], "incomplete proof closure")
    return value, digest(raw)


def enqueue(args):
    worker_ready()
    root = args.proof_root.resolve(strict=True)
    require(root != Path("/") and not args.proof_root.is_symlink(), "unsafe proof root")
    marker = private(root/".lastdb-dev-v2-owner", 4096).decode().strip()
    require(marker.startswith(args.execution_id+":") and marker.endswith(":"+str(root)), "proof owner mismatch")
    status_value = json.loads((root/"status.json").read_bytes())
    connect = json.loads((root/"connect.json").read_bytes())
    restored = json.loads((root/"restore.json").read_bytes())
    accepted = status_value["last_accepted_backup"]
    job = accepted["begin"]["job"]
    stream = job["stream"]
    require(status_value["ok"] and status_value["phase"] == "published" and status_value["backup_kind"] == "snapshot"
            and not status_value["automatic_backup_enabled"] and not status_value["running"], "proof backup is not a stopped manual snapshot")
    require(connect["environment"] == "dev" and connect["manual_backup_enabled"] and not connect["automatic_backup_enabled"]
            and connect["user_hash"] == stream["scope"]["account_id"] == status_value["user_hash"], "proof DEV connection mismatch")
    require(accepted["ordinal"] == "1" and accepted["begin"]["recovery_dependencies"] == []
            and restored["commit_sha256"] == accepted["commit_sha256"] and restored["native_files"] > 0, "proof is not one verified independent snapshot")
    require(Path(restored["destination"]).resolve() == root/"restored", "restore destination mismatch")
    for name in ("home", "restored"):
        home = root/name
        stop = json.loads((home/".shutdown_flush_ready").read_bytes())
        require(stop["version"] == 1 and stop["flush_ok"] is True and stop["pid"] > 0, "proof daemon did not stop cleanly")
        # A live process, even an unrelated reused PID, makes this request wait
        # for an operator rather than authorizing deletion on an ambiguous stop.
        try:
            os.kill(stop["pid"], 0)
        except ProcessLookupError:
            pass
        else:
            raise RuntimeError("proof stop PID is still live")
    request = {"schema":"lastdb.dev-proof-cleanup.v1", "environment":"dev", "api_url":API,
        "execution_id":args.execution_id,"account_id":stream["scope"]["account_id"],
        "account_generation":stream["scope"]["account_generation"],"stream_id":stream["stream_id"],
        "source_home":connect["source_home"],"commit_id":job["commit_id"],"commit_sha256":accepted["commit_sha256"],
        "restore_report_sha256":args.restore_report_sha256,"source_strict_stop":True,"restored_strict_stop":True,
        "source_git_oid":os.environ["LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID"],
        "lastdbd_sha256":os.environ["LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256"],
        "lastdb_sha256":os.environ["LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256"],"created_ms":int(time.time()*1000)}
    path = queue_root()/(request["stream_id"]+".json")
    save(path, request, exclusive=True)
    checked, checksum = request_read(path)
    require(checked == request, "cleanup request readback mismatch")
    save(path.with_suffix(".state.json"), {"request_sha256":checksum,"phase":"waiting","next_attempt_ms":0})
    print(json.dumps({"request":str(path),"sha256":checksum,"state":"queued"}))


def check_receipt(path):
    lines = path.read_text().splitlines()
    values = dict(line.split("=",1) for line in lines)
    require(len(lines)==len(values), "duplicate receipt key")
    request, checksum = request_read(Path(values["cleanup_request"]))
    require(checksum == values["cleanup_request_sha256"], "cleanup request changed")
    mapping = {"execution_id":"loom_execution_id","account_id":"user_hash"}
    for name in ("execution_id","account_id","account_generation","stream_id","source_home","commit_id","commit_sha256",
                 "source_git_oid","lastdbd_sha256","lastdb_sha256","restore_report_sha256"):
        require(request[name] == values[mapping.get(name,name)], "cleanup binding mismatch")
    state = json.loads(private(Path(values["cleanup_request"]).with_suffix(".state.json")))
    require(state["request_sha256"] == checksum and state["phase"] in
        ("waiting","planned","frozen","entries_deleted","objects_deleted","records_deleted","complete")
        and not state.get("error"), "cleanup state is absent or blocked")
    if state["phase"] != "complete":
        worker_ready()


def aws(service, operation, body, provider=None):
    if DELIVERY_DEADLINE is not None and time.monotonic() >= DELIVERY_DEADLINE:
        raise DeliveryYield()
    environment = dict(os.environ, AWS_PAGER="", AWS_CLI_AUTO_PROMPT="off")
    for name in list(environment):
        if name.startswith("AWS_ENDPOINT_URL"):
            environment.pop(name)
    region = REGION
    extra = []
    if provider:
        region = provider["region"]
        environment.update(AWS_ACCESS_KEY_ID=provider["id"], AWS_SECRET_ACCESS_KEY=provider["secret"])
        environment.pop("AWS_SESSION_TOKEN",None)
        extra = ["--endpoint-url",provider["endpoint"]]
    response = subprocess.run(["aws",service,operation,"--region",region,"--output","json","--no-cli-pager",
        "--no-paginate","--cli-input-json","file:///dev/stdin"]+extra,
        input=json.dumps(body),text=True,capture_output=True,env=environment,timeout=90)
    require(response.returncode == 0, "AWS operation refused: "+service+"/"+operation)
    require(len(response.stdout)<50_000_000, "AWS response exceeds cleanup bound")
    return json.loads(response.stdout or "{}")


def key(account, record):
    return {"account_id":{"S":account},"record_id":{"S":record}}


def query(account, prefix):
    rows=[]
    body={"TableName":TABLE,"ConsistentRead":True,"Limit":200,
        "KeyConditionExpression":"account_id=:a AND begins_with(record_id,:p)",
        "ExpressionAttributeValues":{":a":{"S":account},":p":{"S":prefix}}}
    while True:
        page=aws("dynamodb","query",body)
        rows.extend(page.get("Items",[]))
        require(len(rows)<=MAX_ROWS,"scope exceeds bounded cleanup directory")
        if not page.get("LastEvaluatedKey"):
            return rows
        body["ExclusiveStartKey"]=page["LastEvaluatedKey"]


def get(table, item_key):
    return aws("dynamodb","get-item",{"TableName":table,"Key":item_key,"ConsistentRead":True}).get("Item")


def exact(item, operation="ConditionCheck"):
    return {operation:{"TableName":TABLE,"Key":key(item["account_id"]["S"],item["record_id"]["S"]),
        "ConditionExpression":"#r=:r AND #j=:j","ExpressionAttributeNames":{"#r":"revision","#j":"json"},
        "ExpressionAttributeValues":{":r":item["revision"],":j":item["json"]}}}


def absent(account, record):
    return {"ConditionCheck":{"TableName":TABLE,"Key":key(account,record),"ConditionExpression":"attribute_not_exists(record_id)"}}


def transaction(items):
    # A retry of the same transaction cannot apply twice after an ambiguous response.
    token = digest(encoded(items))[:32]
    aws("dynamodb","transact-write-items",{"TransactItems":items,"ClientRequestToken":token})


def providers():
    def secret(name):
        result=subprocess.run(["lastsecrets","get",name],capture_output=True,text=True,timeout=60)
        require(result.returncode==0,"LastSecrets provider credential unavailable")
        return result.stdout.strip()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        kid,app,endpoint,raw=pool.map(secret,["exemem-r2-key-id-dev","exemem-r2-app-key-dev","exemem-r2-endpoint-dev","exemem-b2-credentials-dev-admin"])
    require(re.fullmatch(r"https://[a-z0-9]+\.r2\.cloudflarestorage\.com",endpoint),"unexpected DEV R2 endpoint")
    b2=json.loads(raw)
    return {"r2":{"id":kid,"secret":app,"endpoint":endpoint,"region":"auto","bucket":"exemem-sync-dev"},
        "b2":{"id":b2.get("access_key_id",b2.get("key_id")),"secret":b2.get("secret_access_key",b2.get("app_key")),
            "endpoint":"https://s3.us-east-005.backblazeb2.com","region":"us-east-005","bucket":"exemem-dev"}}


def listing(clients, scope):
    if not clients:
        clients.update(providers())
    result=[]
    prefix="cloud-backup/v2/"+scope+"/"
    for name,client in clients.items():
        body={"Bucket":client["bucket"],"Prefix":prefix}
        operation="list-objects-v2" if name=="r2" else "list-object-versions"
        while True:
            page=aws("s3api",operation,body,client)
            require(not page.get("DeleteMarkers"),"unaccounted provider delete markers")
            for value in page.get("Contents",[])+page.get("Versions",[]):
                result.append({"provider":name,"bucket":client["bucket"],"key":value["Key"],
                    "size":value["Size"],"version":value.get("VersionId"),"etag":value.get("ETag")})
            require(len(result)<=MAX_ROWS,"provider directory exceeds cleanup bound")
            if not page.get("IsTruncated"):
                break
            if name=="r2":
                body["ContinuationToken"]=page["NextContinuationToken"]
            else:
                body.update(KeyMarker=page["NextKeyMarker"],VersionIdMarker=page["NextVersionIdMarker"])
        uploads=aws("s3api","list-multipart-uploads",{"Bucket":client["bucket"],"Prefix":prefix},client)
        require(not uploads.get("Uploads") and not uploads.get("IsTruncated"),"unsettled multipart uploads")
    return result


def identity(binding):
    resource=binding.get("target") or binding.get("resource")
    require(resource is not None,"unbound provider allocation")
    return (resource["endpoint"],binding["bucket"],binding["key"])


def bindings(value):
    if isinstance(value,dict):
        if {"bucket","key"}<=value.keys() and ("target" in value or "resource" in value):
            yield identity(value)
        for child in value.values():
            yield from bindings(child)
    elif isinstance(value,list):
        for child in value:
            yield from bindings(child)


def make_plan(request, checksum, clients):
    scope_value={"account_id":request["account_id"],"account_generation":request["account_generation"]}
    # V2 uses a length-prefixed domain and RFC 8785 JSON. This scope has only
    # ASCII keys and strings, so sorted compact JSON is its canonical encoding.
    domain=b"lastdb:cloud-byte-backup:scope:v2"
    body=encoded(scope_value)
    scope=digest(len(domain).to_bytes(4,"big")+domain+len(body).to_bytes(8,"big")+body)
    account="cb2#"+request["account_id"]
    prefix="s#"+scope+"#"
    items=query(account,prefix)
    rows={v["record_id"]["S"]:{"item":v,"value":json.loads(v["json"]["S"])} for v in items}
    epoch=rows.get(prefix+"retention#epoch")
    if epoch:
        require(not epoch["value"]["frozen"],"scope is owned by another cleanup")
    owners={}
    for record,row in rows.items():
        suffix=record[len(prefix):]
        if suffix.startswith("job#") and suffix.count("#")==1:
            owners[suffix.split("#")[1]]=row["value"]["result"]["job"]["stream"]["stream_id"]
    for record,row in rows.items():
        suffix=record[len(prefix):]
        kind=suffix.split("#")[0]
        value=row["value"]
        owner=None
        if kind=="stream": owner=value["stream"]["stream_id"]
        elif kind=="job": owner=owners.get(suffix.split("#")[1])
        elif kind=="accepted": owner=value.get("backup",value)["begin"]["job"]["stream"]["stream_id"]
        elif kind=="submission": owner=value["input"]["job"]["stream"]["stream_id"]
        elif kind=="restore-hold": owner=value["job"]["stream"]["stream_id"]
        elif kind in ("receipt","reference"):
            allocation=rows.get(value["obligation_key"])
            require(allocation is not None,"canonical allocation is missing")
            owner=allocation["value"]["job"]["stream"]["stream_id"]
        if kind in ("job","accepted","submission","restore-hold","receipt","reference"):
            require(owner is not None,"unknown record ownership")
        row.update(owner=owner,kind=kind,suffix=suffix)
    target=request["stream_id"]
    selected={record:row for record,row in rows.items() if row["owner"]==target}
    stream=selected[prefix+"stream#"+target]["value"]
    require(stream["stream"]["scope"]==scope_value and stream["subject"]==request["account_id"]
        and stream["active_commit_id"] is None and not stream.get("ci_retirement"),"proof stream changed or remains active")
    require(stream["head"]=={"commit_id":request["commit_id"],"commit_sha256":request["commit_sha256"],"ordinal":"1"},"proof head changed")
    jobs=[row for row in selected.values() if row["kind"]=="job" and row["suffix"].count("#")==1]
    accepted=[row for row in selected.values() if row["kind"]=="accepted"]
    require(len(jobs)==len(accepted)==1 and jobs[0]["value"]["result"]["job"]["commit_id"]==request["commit_id"],"proof gained additional jobs")
    backup=accepted[0]["value"]
    require(backup["begin"]["recovery_dependencies"]==[] and backup["commit_sha256"]==request["commit_sha256"],"proof accepted point changed")
    now=int(time.time()*1000)
    due=max([row["value"]["expires_ms"]+1 for row in selected.values() if row["kind"]=="restore-hold"] or [0])
    if due>now:
        return None,due,"restore hold"
    for row in rows.values():
        if row["kind"]=="ci-work" and row["suffix"].count("#")==1 and row["value"]["phase"] not in ("complete","aborted"):
            return None,now+600000,"scope retention"
    for name in ("control","storage_authority"):
        require(get(TABLE,key("personal:"+request["account_id"],name)) is None,"scope authority holder exists")
    protected=set()
    for row in rows.values():
        if row["owner"] and row["owner"]!=target:
            protected.update(bindings(row["value"]))
    allocations=[row for row in rows.values() if row["kind"]=="job" and "#obligation#" in row["suffix"]]
    require(all(row["value"]["state"]["state"] in ("released","retained") for row in allocations),"scope has unsettled allocations")
    retained=[row for row in allocations if row["value"]["state"]["state"]=="retained"]
    target_allocations=[row for row in retained if row["owner"]==target]
    require(target_allocations,"proof has no retained allocations")
    require(all(identity(row["value"]["binding"]) not in protected for row in target_allocations),"proof shares provider objects; retain for reviewed cleanup")
    billed=get(BILLING,{"user_hash":{"S":request["account_id"]}})
    require(billed is not None and "native_backup_counter_format" not in billed,"unsupported billing format")
    counters={k:billed[k] for k in ("native_backup_retained_bytes","native_backup_reserved_bytes","native_backup_allocation_revision")}
    total=sum(row["value"]["state"]["stored_bytes"] for row in retained)
    require(counters["native_backup_reserved_bytes"]=={"N":"0"} and counters["native_backup_retained_bytes"]=={"N":str(total)},"quota does not reconcile with scope ledger")
    physical=listing(clients,scope)
    selected_objects=[]
    for row in target_allocations:
        binding=row["value"]["binding"]
        name=binding["target"]["destination"]
        require(name in clients and identity(binding)[0]==clients[name]["endpoint"] and binding["bucket"]==clients[name]["bucket"]
            and binding["key"].startswith("cloud-backup/v2/"+scope+"/"),"provider binding outside DEV scope")
        matches=[obj for obj in physical if obj["provider"]==name and obj["bucket"]==binding["bucket"] and obj["key"]==binding["key"]]
        require(len(matches)==1 and matches[0]["size"]==row["value"]["state"]["stored_bytes"],"missing or ambiguous proof object")
        if name=="b2":
            require(matches[0]["version"] and matches[0]["version"]==row["value"]["state"]["evidence"]["version_id"],"B2 version mismatch")
        selected_objects.extend(matches)
    require(len({(v["provider"],v["key"],v["version"]) for v in selected_objects})==len(selected_objects),"duplicate physical allocation")
    frozen={"version":1,"scope":scope_value,"request_id":str(uuid.uuid4()),"frozen":True}
    lease={"account_id":{"S":account},"record_id":{"S":prefix+"retention#epoch"},
        "revision":{"N":str(int(epoch["item"]["revision"]["N"])+1 if epoch else 1)},"json":{"S":json.dumps(frozen,separators=(",",":"))}}
    compact=lambda record,row:{"key":record,"revision":row["item"]["revision"],"sha256":digest(row["item"]["json"]["S"].encode())}
    plan={"request_sha256":checksum,"account":account,"scope":scope,"prefix":prefix,"lease":lease,
        "original_epoch":epoch["item"] if epoch else None,"counters":counters,
        "release_bytes":sum(row["value"]["state"]["stored_bytes"] for row in target_allocations),
        "objects":selected_objects,"protected_objects":[obj for obj in physical if obj not in selected_objects],
        "entries":[compact(k,v) for k,v in selected.items() if v["kind"] in ("receipt","reference")],
        "records":[compact(k,v) for k,v in selected.items() if v["kind"] not in ("receipt","reference","stream")],
        "stream":compact(prefix+"stream#"+target,selected[prefix+"stream#"+target]),
        "directory":{record:digest(row["item"]["json"]["S"].encode()) for record,row in rows.items()}}
    return plan,0,"ready"


def authority_checks(request):
    return [absent("personal:"+request["account_id"],name) for name in ("control","storage_authority")]


def quota_condition(plan):
    counters=plan["counters"]
    return {"ConditionExpression":"#ret=:old AND #rev=:rev AND #res=:zero AND attribute_not_exists(#fmt)",
        "ExpressionAttributeNames":{"#ret":"native_backup_retained_bytes","#rev":"native_backup_allocation_revision",
            "#res":"native_backup_reserved_bytes","#fmt":"native_backup_counter_format"},
        "ExpressionAttributeValues":{":old":counters["native_backup_retained_bytes"],":rev":counters["native_backup_allocation_revision"],":zero":{"N":"0"}}}


def delete_rows(request,plan,rows):
    for start in range(0,len(rows),40):
        operations=[exact(plan["lease"])]+authority_checks(request)
        for row in rows[start:start+40]:
            operations.append({"Delete":{"TableName":TABLE,"Key":key(plan["account"],row["key"]),
                "ConditionExpression":"attribute_not_exists(record_id) OR #r=:r","ExpressionAttributeNames":{"#r":"revision"},
                "ExpressionAttributeValues":{":r":row["revision"]}}})
        transaction(operations)
        time.sleep(0.6)


def clean(path,clients):
    request,checksum=request_read(path)
    state_path=path.with_suffix(".state.json")
    state=json.loads(private(state_path))
    require(state["request_sha256"]==checksum,"cleanup state binding changed")
    if state["phase"]=="complete" or state.get("next_attempt_ms",0)>int(time.time()*1000):
        return False
    plan_path=path.with_suffix(".plan.json")
    if state["phase"] in ("waiting","blocked"):
        plan,due,reason=make_plan(request,checksum,clients)
        if plan is None:
            save(state_path,dict(state,phase="waiting",next_attempt_ms=due,waiting_for=reason))
            return False
        save(plan_path,plan)
        save(state_path,dict(state,phase="planned",next_attempt_ms=0,plan_sha256=digest(encoded(plan))))
        state=json.loads(private(state_path))
    plan_raw=private(plan_path,10_000_000)
    require(digest(plan_raw)==state["plan_sha256"],"cleanup plan changed")
    plan=json.loads(plan_raw)
    require(plan["request_sha256"]==checksum,"cleanup plan binding changed")
    account=plan["account"]
    require(account=="cb2#"+request["account_id"] and plan["stream"]["key"]==plan["prefix"]+"stream#"+request["stream_id"],"cleanup plan scope changed")
    if state["phase"]=="planned":
        current=get(TABLE,key(account,plan["lease"]["record_id"]["S"]))
        if current!=plan["lease"]:
            if current!=plan["original_epoch"]:
                save(state_path,dict(state,phase="waiting",next_attempt_ms=int(time.time()*1000)+600000))
                return False
            put=exact(current)["ConditionCheck"] if current else absent(account,plan["lease"]["record_id"]["S"])["ConditionCheck"]
            put.pop("Key")
            put["Item"]=plan["lease"]
            transaction([{"Put":put}]+authority_checks(request)+[{"ConditionCheck":dict(TableName=BILLING,
                Key={"user_hash":{"S":request["account_id"]}},**quota_condition(plan))}])
        current=query(account,plan["prefix"])
        directory={v["record_id"]["S"]:digest(v["json"]["S"].encode()) for v in current if v["record_id"]["S"]!=plan["lease"]["record_id"]["S"]}
        original={k:v for k,v in plan["directory"].items() if k!=plan["lease"]["record_id"]["S"]}
        require(directory==original,"scope changed during freeze; retain exact fence for review")
        state.update(phase="frozen")
        save(state_path,state)
    if state["phase"]=="frozen":
        delete_rows(request,plan,plan["entries"])
        state.update(phase="entries_deleted")
        save(state_path,state)
    if state["phase"]=="entries_deleted":
        require(get(TABLE,key(account,plan["lease"]["record_id"]["S"]))==plan["lease"],"cleanup fence changed")
        physical=listing(clients,plan["scope"])
        require(all(obj in plan["objects"]+plan["protected_objects"] for obj in physical),"provider contents changed")
        for obj in plan["objects"]:
            if obj not in physical:
                continue
            body={"Bucket":obj["bucket"],"Key":obj["key"]}
            if obj["provider"]=="b2": body["VersionId"]=obj["version"]
            aws("s3api","delete-object",body,clients[obj["provider"]])
        physical=listing(clients,plan["scope"])
        require(not any(obj in physical for obj in plan["objects"]),"proof objects remain")
        require(all(obj in physical for obj in plan["protected_objects"]),"protected object missing")
        state.update(phase="objects_deleted")
        save(state_path,state)
    if state["phase"]=="objects_deleted":
        delete_rows(request,plan,plan["records"])
        state.update(phase="records_deleted")
        save(state_path,state)
    if state["phase"]=="records_deleted":
        current=get(TABLE,key(account,plan["stream"]["key"]))
        remaining=int(plan["counters"]["native_backup_retained_bytes"]["N"])-plan["release_bytes"]
        revision=int(plan["counters"]["native_backup_allocation_revision"]["N"])+1
        completion_key=plan["prefix"]+"proof-cleanup#"+request["stream_id"]
        completion={"account_id":{"S":account},"record_id":{"S":completion_key},"revision":{"N":"1"},
            "json":{"S":json.dumps({"request_sha256":checksum,"released_bytes":plan["release_bytes"],
                "retained_after_release":remaining,"allocation_revision":revision},sort_keys=True,separators=(",",":"))}}
        if current is not None:
            condition=quota_condition(plan)
            condition["ExpressionAttributeValues"].update({":new":{"N":str(remaining)},":next":{"N":str(revision)}})
            deletion={"Delete":{"TableName":TABLE,"Key":key(account,plan["stream"]["key"]),
                "ConditionExpression":"#r=:r","ExpressionAttributeNames":{"#r":"revision"},
                "ExpressionAttributeValues":{":r":plan["stream"]["revision"]}}}
            transaction([exact(plan["lease"],"Delete"),deletion]+authority_checks(request)+[{"Update":dict(TableName=BILLING,
                Key={"user_hash":{"S":request["account_id"]}},UpdateExpression="SET #ret=:new,#rev=:next",**condition)},
                {"Put":{"TableName":TABLE,"Item":completion,"ConditionExpression":"attribute_not_exists(record_id)"}}])
        require(get(TABLE,key(account,plan["stream"]["key"])) is None
            and get(TABLE,key(account,completion_key))==completion,"atomic deletion/quota completion receipt missing")
        billed=get(BILLING,{"user_hash":{"S":request["account_id"]}})
        require(int(billed["native_backup_allocation_revision"]["N"])>=revision,"quota revision moved backwards")
        remaining_rows=query(account,plan["prefix"])
        left={v["record_id"]["S"] for v in remaining_rows}
        require(not left.intersection({v["key"] for v in plan["entries"]+plan["records"]+[plan["stream"]]}),"proof records remain")
        remaining_ledger=[json.loads(v["json"]["S"])["state"] for v in remaining_rows if "#job#" in v["record_id"]["S"] and "#obligation#" in v["record_id"]["S"]]
        require(all(v["state"] in ("retained","released") for v in remaining_ledger)
            and sum(v["stored_bytes"] for v in remaining_ledger if v["state"]=="retained")==int(billed["native_backup_retained_bytes"]["N"]),"remaining quota differs from retained ledger")
        physical=listing(clients,plan["scope"])
        require(not any(obj in physical for obj in plan["objects"]) and all(obj in physical for obj in plan["protected_objects"]),"final provider verification differs")
        state.update(phase="complete",completed_ms=int(time.time()*1000),deleted_objects=len(plan["objects"]),
            released_bytes=plan["release_bytes"],remaining_retained_bytes=remaining,allocation_revision=revision,next_attempt_ms=0)
        state.pop("error",None)
        save(state_path,state)
        return True
    return False


def emit(outcome,detail):
    helper=Path(__file__).resolve().parents[3]/"bin/last-stack-brain-append-heartbeat"
    if helper.is_file() and os.access(helper,os.X_OK):
        stamp=datetime.now(timezone.utc).isoformat(timespec="seconds")
        subprocess.run([str(helper),"--line",ROUTINE+" "+stamp+" "+outcome+" "+detail],
            text=True,capture_output=True,timeout=20)
    # Exit zero and ok/noop are the routinesd skip-harness contract. Failures
    # remain explicit in detail and their open Brain papercuts, never a second
    # agent attempting an unplanned deletion.
    print("ROUTINE_RESULT outcome="+outcome+" detail="+detail)


def report_errors(errors):
    def file_error(error):
        reason=error["reason"]
        slug="papercut-dev-proof-cleanup-"+digest(reason.encode())[:12]
        # Targeted discovery before an idempotent filing. The stable reason
        # slug groups repeated occurrences instead of filing one per stream.
        search=subprocess.run(["brain","ask",slug,"--json"],capture_output=True,text=True,timeout=60)
        require(search.returncode==0,"cleanup error search failed")
        body="Automatic DEV proof cleanup retained its request for review: "+json.dumps(error,sort_keys=True)+". Repo EdgeVector/last-stack. Inspect the exact request and saved phase; do not clear a fence or widen deletion targets."
        result=subprocess.run(["brain","papercut","file",slug,"--component","dev-proof-cleanup","--severity","p2",
            "--title","DEV proof cleanup blocked: "+reason,"--symptom",reason,"--body",body],capture_output=True,text=True,timeout=60)
        require(result.returncode==0,"cleanup papercut filing failed")
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(file_error,errors))


def drain():
    global DELIVERY_DEADLINE
    root=queue_root()
    if not root.exists():
        emit("noop","no DEV proof cleanup requests")
        return
    require(not root.is_symlink() and root.stat().st_uid==os.getuid(),"unsafe cleanup queue")
    lock=os.open(root/".worker.lock",os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    with os.fdopen(lock,"w") as held:
        try:
            fcntl.flock(held,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:
            emit("noop","cleanup worker already active")
            return
        paths=sorted(p for p in root.glob("*.json") if re.fullmatch(r"[0-9a-f-]{36}\.json",p.name))
        require(len(paths)<=100,"cleanup queue exceeds bounded request count")
        pending=[]
        for path in paths:
            state_path=path.with_suffix(".state.json")
            if not state_path.exists():
                _,checksum=request_read(path)
                save(state_path,{"request_sha256":checksum,"phase":"waiting","next_attempt_ms":0})
            state=json.loads(private(state_path))
            if ((state["phase"]!="complete" and state.get("next_attempt_ms",0)<=int(time.time()*1000))
                    or (state["phase"]=="complete" and not state.get("closeout_reported"))): pending.append(path)
        if not pending:
            emit("noop","cleanup requests complete or awaiting their holds")
            return
        needs_provider=any(json.loads(private(path.with_suffix(".state.json")))["phase"]!="complete" for path in pending)
        clients={}
        if needs_provider:
            require(aws("sts","get-caller-identity",{})["Account"]==AWS_ACCOUNT,"unexpected AWS account")
        complete=[]
        errors=[]
        deadline=time.monotonic()+480
        DELIVERY_DEADLINE=deadline
        for path in pending:
            if time.monotonic()>deadline: break
            try:
                clean(path,clients)
                final=json.loads(private(path.with_suffix(".state.json")))
                if final["phase"]=="complete" and not final.get("closeout_reported"):
                    complete.append(path.stem)
            except DeliveryYield:
                break
            except (RuntimeError,KeyError,ValueError,OSError,subprocess.SubprocessError) as failure:
                # Exception strings are fixed local reasons; never persist an AWS
                # response, provider credentials, a signed URL or raw JSON row.
                reason=str(failure) if isinstance(failure,RuntimeError) else type(failure).__name__
                errors.append({"stream_id":path.stem,"reason":reason})
                state_path=path.with_suffix(".state.json")
                state=json.loads(private(state_path))
                state.update(error=reason,next_attempt_ms=int(time.time()*1000)+600000)
                save(state_path,state)
        if complete or errors:
            if errors:
                report_errors(errors)
            report="\n\nDEV proof cleanup worker: "+json.dumps({"completed_streams":complete,"errors":errors},sort_keys=True)+"\n"
            result=subprocess.run(["brain","append","reference-dev-proof-automatic-cleanup-20261103","--type","reference"],input=report,text=True,capture_output=True,timeout=60)
            require(result.returncode==0,"cleanup finished but Brain closeout append failed")
            for stream in complete:
                state_path=root/(stream+".state.json")
                state=json.loads(private(state_path))
                save(state_path,dict(state,closeout_reported=True))
        print(json.dumps({"completed_streams":complete,"errors":errors},sort_keys=True))
        emit("ok",("blocked" if errors else "cleanup pass")+" completed="+str(len(complete))+" errors="+str(len(errors)))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    modes=parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--enqueue",action="store_true")
    modes.add_argument("--check-receipt",type=Path)
    modes.add_argument("--drain",action="store_true")
    modes.add_argument("--ready",action="store_true")
    parser.add_argument("--proof-root",type=Path)
    parser.add_argument("--execution-id")
    parser.add_argument("--restore-report-sha256")
    args=parser.parse_args()
    try:
        if args.enqueue:
            require(args.proof_root and args.execution_id and re.fullmatch(r"[0-9a-f]{64}",args.restore_report_sha256 or ""),"incomplete cleanup enqueue arguments")
            enqueue(args)
        elif args.check_receipt: check_receipt(args.check_receipt)
        elif args.ready: worker_ready()
        else: drain()
    except (RuntimeError,KeyError,ValueError,OSError,subprocess.SubprocessError) as failure:
        reason=str(failure) if isinstance(failure,RuntimeError) else type(failure).__name__
        print("DEV_PROOF_CLEANUP: RED: "+reason,file=sys.stderr)
        return 1
    return 0


if __name__=="__main__":
    sys.exit(main())
