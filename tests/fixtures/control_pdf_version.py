#!/usr/bin/env python3
"""Guarded synthetic PDF version acceptance; preview never uses the network.

This is a manual test control, not a product replacement/repair API. Execution
is restricted to the frozen loopback library and one explicitly named object.
No SQLite/PG writes, native credentials, or automatic conflict resolution.
"""
from __future__ import annotations

import argparse
import copy
import datetime
import hashlib
import json
import os
from pathlib import Path
import sys
import urllib.error
import urllib.request

ORIGIN = "http://127.0.0.1:53056"
LIBRARY = "97c6c216-19ef-4e34-b97f-fecbf4653702"
EPOCH = "08874133-4249-485c-8829-93d98cdb7485"
OBJECT = "afecb79c-e124-4869-bbff-a72bafcbb684"
PUBLIC_FIELDS = {"id", "revision", "trashBatchId", "conflictIds", "purgeAt"}


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def encoded(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()


def persist(path, value):
    raw = encoded(value)
    if path.exists():
        require(path.read_bytes() == raw, f"Refusing to replace frozen evidence: {path}")
    else:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as stream:
            stream.write(raw)
    return raw


def business(snapshot):
    return {k: v for k, v in snapshot.items() if k not in PUBLIC_FIELDS}


def without_reading(snapshot):
    result = copy.deepcopy(business(snapshot))
    for key in ("readingPositions", "readingStatus"):
        result.get("metadata", {}).pop(key, None)
    return result


def expected_switched(prepared):
    result = copy.deepcopy(prepared["baselineSnapshot"])
    result["pdfBlobId"] = prepared["newBlobId"]
    for annotation in result["annotations"]:
        annotation["placementState"] = "needs_review"
    return result


class API:
    def __init__(self):
        self.token = None
        # Local test traffic must not use a shell/user proxy configuration.
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self, method, path, value=None, *, raw=None, headers=None, missing=False, binary=False):
        request_headers = {"X-Library-Epoch": EPOCH}
        if self.token:
            request_headers["Authorization"] = "Bearer " + self.token
        if value is not None:
            raw = encoded(value)
            request_headers["Content-Type"] = "application/json"
        if headers:
            request_headers.update(headers)
        request = urllib.request.Request(ORIGIN + "/api/v1" + path, raw, request_headers, method=method)
        try:
            with self.opener.open(request, timeout=15) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            if missing and error.code == 404:
                return None
            # Do not log request headers, login payload, or successful tokens.
            try:
                reason = json.loads(error.read()).get("error", {})
            except (ValueError, TypeError):
                reason = {}
            raise RuntimeError(f"HTTP {error.code}; code={reason.get('code')}; "
                               f"Retry-After={error.headers.get('Retry-After')}; rerun the same frozen operation") from None
        return body if binary else json.loads(body)["data"]

    def object(self):
        snapshot = self.request("GET", "/objects/" + OBJECT)["snapshot"]
        require(snapshot["id"] == OBJECT and snapshot["state"] == "active", "Target identity/state changed")
        require(not snapshot.get("conflictIds") and not snapshot.get("purgeAt"), "Target has conflicts/retention")
        return snapshot

    def blob(self, blob_id, sha, size):
        raw = self.request("GET", "/blobs/" + blob_id, binary=True)
        require(len(raw) == size and hashlib.sha256(raw).hexdigest() == sha, "Blob bytes/hash mismatch")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("prepared", type=Path)
    parser.add_argument("--execute", choices=("switch", "rollback"))
    parser.add_argument("--confirm-object")
    args = parser.parse_args()
    prepared = json.loads(args.prepared.read_text())
    require((prepared["origin"], prepared["libraryId"], prepared["epoch"], prepared["objectId"])
            == (ORIGIN, LIBRARY, EPOCH, OBJECT), "Frozen control targets another environment")
    for prefix in ("old", "new"):
        raw = Path(prepared[prefix + "File"]).read_bytes()
        require(len(raw) == prepared[prefix + "Bytes"] and hashlib.sha256(raw).hexdigest()
                == prepared[prefix + "SHA256"], f"{prefix} fixture changed")
    require(prepared["oldSHA256"] != prepared["newSHA256"], "Two editions must differ")
    if not args.execute:
        print(json.dumps({"mode": "preview-only-no-network", "origin": ORIGIN, "objectId": OBJECT,
                          "baselineRevision": prepared["baselineRevision"], "oldBlobId": prepared["oldBlobId"],
                          "newBlobId": prepared["newBlobId"], "switchChanges": ["pdfBlobId", "annotations[].placementState"],
                          "rollbackChanges": ["pdfBlobId", "original attached annotations", "baseline readingPositions/readingStatus"],
                          "note": "No login/upload/write performed. Rollback rejects other edits."}, indent=2))
        return

    require(args.confirm_object == OBJECT, "Execution requires the exact synthetic --confirm-object")
    username, password = os.environ.get("TEST_TOKENLIBRARY_USER"), os.environ.get("TEST_TOKENLIBRARY_PASSWORD")
    require(username and password, "Provide the synthetic test credentials via TEST_TOKENLIBRARY_USER/PASSWORD")
    api = API()
    try:
        login = api.request("POST", "/auth/login", {"username": username, "password": password,
                            "deviceId": prepared["deviceId"], "deviceName": "PDF version acceptance control", "platform": "test"})
        api.token = login.pop("sessionToken")
        require((login["libraryId"], login["epoch"], login["deviceId"]) ==
                (LIBRARY, EPOCH, prepared["deviceId"]), "Login identity/epoch mismatch")
        meta = api.request("GET", "/meta")
        require(meta["libraryId"] == LIBRARY and meta["epoch"] == EPOCH and not meta["maintenance"], "Library not ready")
        api.blob(prepared["oldBlobId"], prepared["oldSHA256"], prepared["oldBytes"])
        action = args.execute
        operation = prepared[action + "OperationId"]
        previous = api.request("GET", "/sync/operations/" + operation, missing=True)
        if previous is not None:
            require(previous["status"] == "committed" and previous["objectId"] == OBJECT, "Prior operation is not committed")
            print(json.dumps({"alreadyCommitted": operation, "revision": previous["revision"],
                              "note": "No replacement operation sent; inspect current object separately."}))
            return
        snapshot = api.object()
        if action == "switch":
            require(int(snapshot["revision"]) == prepared["baselineRevision"] and
                    business(snapshot) == prepared["baselineSnapshot"], "Target changed since preparation; do not overwrite")
            upload = api.request("POST", "/uploads", {"blobId": prepared["newBlobId"], "size": prepared["newBytes"],
                                 "sha256": prepared["newSHA256"], "mime": "application/pdf"})
            require(upload["blobId"] == prepared["newBlobId"], "Upload identity mismatch")
            if upload["state"] != "complete":
                path = "/uploads/" + upload["uploadId"]
                status = api.request("GET", path)
                raw = Path(prepared["newFile"]).read_bytes()
                chunk_size = int(status["chunkSize"])
                require(0 < chunk_size <= 1048576, "Unexpected chunk size")
                for index, start in enumerate(range(0, len(raw), chunk_size)):
                    if index in status["chunks"]:
                        continue
                    chunk = raw[start:start + chunk_size]
                    api.request("PUT", path + "/chunks/" + str(index), raw=chunk,
                                headers={"Content-Type": "application/octet-stream", "X-Chunk-SHA256": hashlib.sha256(chunk).hexdigest()})
                api.request("POST", path + "/complete", {})
            api.blob(prepared["newBlobId"], prepared["newSHA256"], prepared["newBytes"])
            require(api.object() == snapshot, "Target changed during upload; no update sent")
            desired = {"pdfBlobId": prepared["newBlobId"]}
        else:
            switched = api.request("GET", "/sync/operations/" + prepared["switchOperationId"], missing=True)
            require(switched and switched["status"] == "committed", "Switch receipt not committed")
            require(without_reading(snapshot) == without_reading(expected_switched(prepared)),
                    "New annotations, metadata, names, relationships, or other edits detected; do not overwrite")
            # Restoring the old blob alone intentionally does not clear needs_review.
            # This explicit test rollback restores the frozen original coordinates
            # and reading state only after rejecting unrelated intervening edits.
            desired = {"pdfBlobId": prepared["oldBlobId"],
                       "annotations": copy.deepcopy(prepared["baselineSnapshot"]["annotations"]),
                       "metadata": copy.deepcopy(prepared["baselineSnapshot"]["metadata"])}
        wire = {"protocolVersion": 1, "operationId": operation, "epoch": EPOCH,
                "deviceId": prepared["deviceId"], "objectId": OBJECT, "action": "updateDocument",
                "base": {"source": "revision", "revision": int(snapshot["revision"])}, "desiredSnapshot": desired}
        # A retry may reuse a frozen payload, but never silently change its base.
        frozen = persist(args.prepared.parent / (action + "-request.json"), wire)
        result = api.request("POST", "/sync/operations", raw=frozen,
                             headers={"Content-Type": "application/json", "Idempotency-Key": operation})
        require(result["status"] == "committed" and result["objectId"] == OBJECT, "Operation conflicted; preserve evidence and stop")
        after = api.object()
        expected = expected_switched(prepared) if action == "switch" else prepared["baselineSnapshot"]
        require(without_reading(after) == without_reading(expected), "Unexpected post-operation state; do not force another write")
        api.blob(prepared["oldBlobId"], prepared["oldSHA256"], prepared["oldBytes"])
        evidence = {"at": datetime.datetime.now().astimezone().isoformat(), "action": action,
                    "dedicatedSessionId": login["sessionId"], "before": snapshot, "after": after,
                    "result": result, "oldBlobBytesPreserved": True}
        persist(args.prepared.parent / (action + "-result.json"), evidence)
        print(json.dumps({"committed": operation, "revision": after["revision"], "action": action}))
    finally:
        if api.token:
            try:
                api.request("POST", "/auth/logout", {})
            except Exception as error:
                print("Dedicated test-session logout did not confirm: " + str(error), file=sys.stderr)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        raise SystemExit(str(error)) from None
