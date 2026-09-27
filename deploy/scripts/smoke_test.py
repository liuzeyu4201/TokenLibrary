#!/usr/bin/env python3
"""Opt-in Docker smoke test. Uses unique containers, private network and disposable data."""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid
from urllib.request import urlopen


def run(*args, input=None):
    result = subprocess.run(["docker", *args], input=input, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result.stdout.strip()


def wait_until(check, label, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            result = check()
            if result:
                return result
        except (OSError, RuntimeError):
            pass
        time.sleep(0.5)
    raise RuntimeError(f"timed out waiting for {label}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--image", default="tokenlibrary-validation:20260926")
    args = parser.parse_args()
    suffix = uuid.uuid4().hex[:12]
    network, database, app = [f"tl-smoke-{kind}-{suffix}" for kind in ("net", "pg", "app")]
    root = Path(tempfile.mkdtemp(prefix="tl-container-smoke-")).resolve()
    # Permission relaxation is confined to disposable fixture directories, never user configuration.
    for child in ("data", "backup", "restored"):
        (root / child).mkdir(mode=0o777)
        (root / child).chmod(0o777)
    password = uuid.uuid4().hex
    db_url = f"postgres://tl:{password}@{database}:5432/tl?sslmode=disable"
    try:
        run("network", "create", network)
        run("run", "--rm", "-d", "--name", database, "--network", network,
            "-e", "POSTGRES_USER=tl", "-e", f"POSTGRES_PASSWORD={password}", "-e", "POSTGRES_DB=tl",
            "postgres:17-bookworm@sha256:639ab7ceb90e13123085b741fb31ef493fba25463002f6da665352e7b534b652")
        wait_until(lambda: "accepting connections" in run("exec", database, "pg_isready", "-U", "tl"), "PostgreSQL")
        # Valid Argon2id fixture: credentials are not used by the smoke probe and no admin endpoint is exposed.
        fixture_hash = "$argon2id$v=19$m=65536,t=3,p=1$c21va2UtZml4dHVyZS1zYWx0$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        run("run", "--rm", "-d", "--name", app, "--network", network,
            "-p", "127.0.0.1::8080", "-v", f"{root / 'data'}:/data", "-v", f"{root / 'backup'}:/backup", "-v", f"{root / 'restored'}:/restored",
            "-e", f"DATABASE_URL={db_url}", "-e", "DATA_ROOT=/data", "-e", "BACKUP_ROOT=/backup",
            "-e", "ADMIN_USERNAME=smoke", "-e", f"ADMIN_PASSWORD_HASH={fixture_hash}", "-e", "UPLOAD_TOKEN_ENABLED=false",
            "-e", "PUBLIC_BASE_URL=http://127.0.0.1:8080", "-e", "TOKENLIBRARY_TEST_HOOKS=0", args.image)
        address = run("port", app, "8080/tcp").splitlines()[0]
        def ready():
            with urlopen(f"http://{address}/health/ready", timeout=2) as response:
                return response.status == 200
        wait_until(ready, "application ready")
        def published():
            return next((p for p in (root / "backup").iterdir() if p.is_dir() and (p / "manifest.json").exists() and not p.name.startswith(".")), None)
        backup = wait_until(published, "scheduled real backup")
        manifest = json.loads((backup / "manifest.json").read_text())
        run("exec", app, "library-admin", "verify", "--backup", f"/backup/{backup.name}")
        run("exec", database, "createdb", "-U", "tl", "restored")
        restore_url = db_url.replace("/tl?", "/restored?")
        run("exec", "-e", f"RESTORE_DATABASE_URL={restore_url}", app, "library-admin", "restore", "--backup", f"/backup/{backup.name}", "--data-root", "/restored")
        restored = run("exec", database, "psql", "-U", "tl", "-d", "restored", "-At", "-F", "|", "-c", "SELECT id,epoch,maintenance FROM libraries").split("|")
        if restored[0] != manifest["libraryId"] or restored[1] == manifest["epoch"] or restored[2] != "f":
            raise RuntimeError("restored identity, epoch or maintenance state failed")
        print("PASS: container startup, PG17 scheduled custom dump, manifest verification, isolated CLI restore, stable libraryId and new epoch")
    finally:
        for container in (app, database):
            subprocess.run(["docker", "rm", "-f", container], capture_output=True)
        subprocess.run(["docker", "network", "rm", network], capture_output=True)
        shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    main()
