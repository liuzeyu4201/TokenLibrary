#!/usr/bin/env python3
"""Prepare or execute one guarded synthetic Markdown edit during native typing.

freeze reads only the named isolated PostgreSQL object. preview is offline.
submit uses one dedicated e2e HTTP session and the immutable operation envelope.
Never use submit until the native operator explicitly says to submit now.
"""
from __future__ import annotations

import argparse
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.request
import uuid

ORIGIN = "http://127.0.0.1:53056"
LIBRARY = "97c6c216-19ef-4e34-b97f-fecbf4653702"
EPOCH = "08874133-4249-485c-8829-93d98cdb7485"
CONTAINER = "tl-restored-b399c867c3db"
NAME = "双端连续输入验收.md"
REPAIR_NAME = "双端连续输入验收_修复.md"
MAC_NAME = "双端连续输入验收_Mac.md"
RICH_IOS_NAME = "双端排版连续输入_iOS.md"
RICH_MAC_NAME = "双端排版连续输入_Mac.md"
ALLOWED_NAMES = (NAME, REPAIR_NAME, MAC_NAME, RICH_IOS_NAME, RICH_MAC_NAME)
BASE = "Remote: base\n\nLocal: base\n\nTail: keep\n"
LOCAL_BASE = "Local: base"
LOCAL_FINAL = "Local: base-01-02-03-04-05-06-07-08-XYZ \n"
PUBLIC_FIELDS = {"id", "revision", "trashBatchId", "conflictIds", "purgeAt"}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def now():
    return datetime.datetime.now().astimezone().isoformat()


def persist(path, value):
    raw = encoded(value)
    if path.exists():
        require(path.read_bytes() == raw, "Refusing to replace frozen evidence: " + str(path))
    else:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
    return raw


def business(snapshot):
    return {key: value for key, value in snapshot.items() if key not in PUBLIC_FIELDS}


def local_part(markdown, remote):
    prefix, suffix = "Remote: " + remote + "\n\n", "\n\nTail: keep\n"
    require(isinstance(markdown, str) and markdown.startswith(prefix) and markdown.endswith(suffix),
            "Remote, separators, or Tail changed; refusing to write")
    return markdown[len(prefix):-len(suffix)]


def validate_current(plan, snapshot, *, committed=False):
    require(snapshot.get("id") == plan["objectId"], "Unexpected object identity")
    require(snapshot.get("state") == "active" and not snapshot.get("conflictIds") and not snapshot.get("purgeAt"),
            "Object deleted, conflicted, or retained; refusing to write")
    require(int(snapshot["revision"]) >= plan["baseRevision"], "Server revision went backwards")
    actual, baseline = business(snapshot), copy.deepcopy(plan["baseSnapshot"])
    local = local_part(actual.pop("markdownSource", None), plan["remoteMarker"] if committed else "base")
    baseline.pop("markdownSource")
    require(actual == baseline, "Non-body fields changed since the frozen base; refusing to write")
    require(local.startswith(LOCAL_BASE) and plan["localTarget"].startswith(local),
            "Local text is not a prefix of the agreed typing sequence; refusing to write")
    return local


def make_plan(object_id, revision, snapshot, local_target, expected_name=NAME):
    require(str(uuid.UUID(object_id)) == object_id, "Use the exact lowercase object UUID")
    require(expected_name in ALLOWED_NAMES, "Unexpected acceptance fixture name")
    require(snapshot.get("kind") == "md" and snapshot.get("name") == expected_name and snapshot.get("state") == "active",
            "Only the explicitly named new synthetic Markdown note is allowed")
    require(snapshot.get("markdownSource") == BASE, "Initial body differs from the agreed exact fixture")
    require(local_target.startswith(LOCAL_BASE) and len(local_target) > len(LOCAL_BASE)
            and len(local_target) <= 512 and "\r" not in local_target
            and ("\n" not in local_target or local_target.endswith("\n") and local_target.count("\n") == 1),
            "Local target must append at most 512 characters and an optional final LF")
    marker = "REMOTE-" + uuid.uuid4().hex[:12]
    operation, device = str(uuid.uuid4()), str(uuid.uuid4())
    wire = {"protocolVersion": 1, "operationId": operation, "epoch": EPOCH, "deviceId": device,
            "objectId": object_id, "action": "updateDocument",
            "base": {"source": "revision", "revision": int(revision)},
            "desiredSnapshot": {"markdownSource": BASE.replace("Remote: base", "Remote: " + marker, 1)}}
    return {"preparedAt": now(), "origin": ORIGIN, "libraryId": LIBRARY, "epoch": EPOCH,
            "objectId": object_id, "expectedName": expected_name, "baseRevision": int(revision), "baseSnapshot": business(snapshot),
            "localTarget": local_target, "remoteMarker": marker, "wire": wire,
            "wireSHA256": hashlib.sha256(encoded(wire)).hexdigest()}


def freeze(args):
    object_id = str(uuid.UUID(args.object_id))
    require(object_id == args.object_id, "Use the exact lowercase object UUID")
    # UUID validation is completed before constructing the read-only SQL.
    sql = f"""BEGIN READ ONLY;
SELECT coalesce(json_agg(json_build_object('id',o.id,'revision',o.revision,
 'snapshot',convert_from(r.snapshot_bytes,'UTF8')::json)), '[]')
FROM objects o JOIN libraries l ON l.id=o.library_id
JOIN revisions r ON r.library_id=l.id AND r.epoch=l.epoch AND r.object_id=o.id AND r.revision=o.revision
WHERE l.id='{LIBRARY}' AND l.epoch='{EPOCH}' AND l.maintenance=false
 AND o.id='{object_id}' AND o.state='active';
COMMIT;"""
    rows = json.loads(subprocess.check_output(["docker", "exec", CONTAINER, "psql", "-X", "-U", "tl", "-d", "tl",
        "-Atq", "-v", "ON_ERROR_STOP=1", "-c", sql], text=True))
    require(len(rows) == 1 and rows[0]["id"] == object_id, "Expected exactly the selected object in the isolated epoch")
    row = rows[0]
    plan = make_plan(object_id, row["revision"], row["snapshot"], args.local_target, args.name)
    args.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(not (args.directory / "prepared.json").exists(), "This directory already has a frozen plan")
    persist(args.directory / "operation-request.json", plan["wire"])
    persist(args.directory / "prepared.json", plan)
    preview(plan)


def read_plan(path):
    plan = json.loads(path.read_text())
    require((plan["origin"], plan["libraryId"], plan["epoch"]) == (ORIGIN, LIBRARY, EPOCH), "Unexpected environment")
    wire = plan["wire"]
    require(wire["objectId"] == plan["objectId"] and str(uuid.UUID(plan["objectId"])) == plan["objectId"], "Identity mismatch")
    require(wire["epoch"] == EPOCH and wire["base"] == {"source": "revision", "revision": plan["baseRevision"]}
            and wire["action"] == "updateDocument" and wire["protocolVersion"] == 1, "Unexpected operation")
    require(wire["desiredSnapshot"] == {"markdownSource": BASE.replace("Remote: base", "Remote: " + plan["remoteMarker"], 1)},
            "Frozen operation changes more than Remote")
    require(hashlib.sha256(encoded(wire)).hexdigest() == plan["wireSHA256"], "Frozen wire hash changed")
    require((path.parent / "operation-request.json").read_bytes() == encoded(wire), "Frozen request bytes changed")
    expected_name = plan.get("expectedName", NAME)
    require(expected_name in ALLOWED_NAMES and plan["baseSnapshot"]["name"] == expected_name
            and plan["baseSnapshot"]["markdownSource"] == BASE, "Unexpected fixture")
    return plan


def preview(plan):
    print(json.dumps({"mode": "prepared-no-http", "origin": ORIGIN, "objectId": plan["objectId"],
        "baseRevision": plan["baseRevision"], "operationId": plan["wire"]["operationId"],
        "remoteMarker": plan["remoteMarker"], "localTarget": plan["localTarget"],
        "rule": "Only prefixes of the agreed Local target may advance; all other business fields remain frozen"}, ensure_ascii=False, indent=2))


class API:
    def __init__(self):
        self.token = None
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, request, fp, code, message, headers, new_url):
                return None
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())

    def call(self, method, path, *, value=None, raw=None, operation=None, missing=False):
        headers = {"Content-Type": "application/json", "X-Library-Epoch": EPOCH}
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        if operation:
            headers["Idempotency-Key"] = operation
        request = urllib.request.Request(ORIGIN + "/api/v1" + path,
            encoded(value) if value is not None else raw, headers, method=method)
        try:
            with self.opener.open(request, timeout=15) as response:
                return json.load(response)["data"]
        except urllib.error.HTTPError as error:
            if missing and error.code == 404:
                return None
            raise RuntimeError(f"HTTP {error.code}; Retry-After={error.headers.get('Retry-After')}; stop and reuse the frozen operation") from None


def submit(args):
    plan = read_plan(args.prepared)
    require(args.confirm_object == plan["objectId"], "Explicit --confirm-object must match")
    require(os.environ.get("TEST_TOKENLIBRARY_USER") == "e2e", "Only the synthetic e2e account is allowed")
    password = os.environ.get("TEST_TOKENLIBRARY_PASSWORD")
    require(password, "Supply the synthetic password through TEST_TOKENLIBRARY_PASSWORD")
    api, wire = API(), plan["wire"]
    attempt = {"startedAt": now(), "objectId": plan["objectId"], "operationId": wire["operationId"], "baseRevision": plan["baseRevision"]}
    evidence = args.prepared.parent / ("attempt-" + uuid.uuid4().hex + ".json")
    try:
        login = api.call("POST", "/auth/login", value={"username": "e2e", "password": password,
            "deviceId": wire["deviceId"], "deviceName": "Native typing interleaving control", "platform": "test"})
        api.token = login.pop("sessionToken")
        require((login["libraryId"], login["epoch"], login["deviceId"]) == (LIBRARY, EPOCH, wire["deviceId"]), "Login identity changed")
        attempt["dedicatedSessionId"] = login["sessionId"]
        meta = api.call("GET", "/meta")
        require(meta["libraryId"] == LIBRARY and meta["epoch"] == EPOCH and not meta["maintenance"], "Unexpected library/maintenance")
        result = api.call("GET", "/sync/operations/" + wire["operationId"], missing=True)
        if result is not None:
            require(result["status"] == "committed" and result["objectId"] == plan["objectId"], "Previous receipt is not committed")
            attempt.update(alreadyCommitted=True, receipt=result)
            print(json.dumps({"alreadyCommitted": wire["operationId"], "revision": result["revision"], "noWriteSent": True}))
            return
        before = api.call("GET", "/objects/" + plan["objectId"])["snapshot"]
        attempt.update(beforeAt=now(), before=before)
        prior_local = validate_current(plan, before)
        # Intentionally keep base r even if legitimate Local edits advanced the
        # current revision. Server three-way merge must preserve those edits.
        attempt["submittedAt"] = now()
        result = api.call("POST", "/sync/operations", raw=(args.prepared.parent / "operation-request.json").read_bytes(), operation=wire["operationId"])
        attempt.update(receivedAt=now(), receipt=result)
        require(result["status"] == "committed" and result["objectId"] == plan["objectId"], "Unexpected/conflicted receipt; stop")
        after = api.call("GET", "/objects/" + plan["objectId"])["snapshot"]
        attempt.update(afterAt=now(), after=after)
        after_local = validate_current(plan, after, committed=True)
        require(after_local.startswith(prior_local), "Local prefix regressed; preserve evidence and stop")
        print(json.dumps({"committed": wire["operationId"], "revision": result["revision"],
            "remoteMarker": plan["remoteMarker"], "submittedAt": attempt["submittedAt"],
            "receivedAt": attempt["receivedAt"], "proof": str(evidence)}, ensure_ascii=False))
    except Exception as error:
        attempt["error"] = str(error)
        raise
    finally:
        if api.token:
            try:
                result = api.call("POST", "/auth/logout", value={})
                attempt["dedicatedSessionLoggedOut"] = result.get("loggedOut") is True
            except Exception as error:
                attempt["logoutError"] = str(error)
                print("Dedicated control-session logout did not confirm", file=sys.stderr)
        attempt["finishedAt"] = now()
        persist(evidence, attempt)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    freeze_parser = modes.add_parser("freeze", help="Read-only isolated DB snapshot; no login or HTTP")
    freeze_parser.add_argument("--object-id", required=True)
    freeze_parser.add_argument("--directory", type=Path, required=True)
    freeze_parser.add_argument("--name", choices=ALLOWED_NAMES, default=NAME)
    freeze_parser.add_argument("--local-target", default=LOCAL_FINAL)
    preview_parser = modes.add_parser("preview", help="Offline preview of an existing frozen plan")
    preview_parser.add_argument("prepared", type=Path)
    submit_parser = modes.add_parser("submit", help="Only after the native operator explicitly says submit now")
    submit_parser.add_argument("prepared", type=Path)
    submit_parser.add_argument("--confirm-object", required=True)
    args = parser.parse_args()
    if args.mode == "freeze":
        freeze(args)
    elif args.mode == "preview":
        preview(read_plan(args.prepared))
    else:
        submit(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit(str(error)) from None
