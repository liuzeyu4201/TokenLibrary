#!/usr/bin/env python3
"""Validated Compose entry point. Never source .env as shell code or print its secrets."""
from __future__ import annotations
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.parse import urlsplit
from urllib.request import urlopen
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

ROOT = Path(__file__).resolve().parents[2]
ENV_KEYS = set("DEPLOYMENT PUBLIC_BASE_URL DATA_ROOT BACKUP_ROOT ADMIN_USERNAME ADMIN_PASSWORD_HASH UPLOAD_TOKEN_HASH UPLOAD_TOKEN_ENABLED POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DATA_ROOT ACME_EMAIL ACME_CA APP_UID APP_GID BACKUP_TIME BACKUP_TIMEZONE BACKUP_TIMEOUT LOG_LEVEL TOKENLIBRARY_TEST_HOOKS CREDENTIAL_GENERATION".split())

def read_settings(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line_number, raw in enumerate(path.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise ValueError(f"invalid configuration line {line_number}")
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key) or key in result:
            raise ValueError(f"invalid or duplicate configuration key at line {line_number}")
        if value.startswith(("'", '"')):
            if len(value) < 2 or value[-1] != value[0]:
                raise ValueError(f"unclosed configuration quote at line {line_number}")
            value = value[1:-1]
        result[key] = value
    # Docker Compose gives exported variables priority over .env.
    for key in ENV_KEYS | result.keys():
        if key in os.environ:
            result[key] = os.environ[key]
    return result

def validate(settings: dict[str, str], root: Path = ROOT) -> tuple[Path, Path, str]:
    required = ["DATA_ROOT", "BACKUP_ROOT", "POSTGRES_PASSWORD", "ADMIN_USERNAME", "ADMIN_PASSWORD_HASH"]
    for key in required:
        if not settings.get(key):
            raise ValueError(f"{key} is required")
    data, backup = Path(settings["DATA_ROOT"]), Path(settings["BACKUP_ROOT"])
    for label, path in (("DATA_ROOT", data), ("BACKUP_ROOT", backup)):
        if not path.is_absolute() or path == Path("/"):
            raise ValueError(f"{label} must be an absolute path other than /")
        if path.resolve() != path:
            raise ValueError(f"{label} must not contain symlinks or '..'")
        if path == root or root in path.parents or path in root.parents:
            raise ValueError(f"{label} must be separate from the source checkout")
    if data == backup or data in backup.parents or backup in data.parents:
        raise ValueError("DATA_ROOT and BACKUP_ROOT must not overlap")
    if settings.get("POSTGRES_DATA_ROOT"):
        pg = Path(settings["POSTGRES_DATA_ROOT"])
        if not pg.is_absolute() or pg == Path("/") or pg.resolve() != pg or pg == root or root in pg.parents or pg in root.parents:
            raise ValueError("POSTGRES_DATA_ROOT must be an absolute directory separate from the checkout without symlinks")
        if pg in (data, backup) or pg in data.parents or pg in backup.parents or backup in pg.parents:
            raise ValueError("POSTGRES_DATA_ROOT must not contain DATA_ROOT or overlap BACKUP_ROOT")
    deployment = settings.get("DEPLOYMENT", "local")
    if deployment not in ("local", "server"):
        raise ValueError("DEPLOYMENT must be local or server")
    public = urlsplit(settings.get("PUBLIC_BASE_URL", ""))
    if not public.hostname or public.username or public.password or public.path not in ("", "/") or public.query or public.fragment:
        raise ValueError("PUBLIC_BASE_URL must be a server origin without credentials, path or query")
    if deployment == "server":
        if public.scheme != "https" or public.port not in (None, 443):
            raise ValueError("server deployment requires PUBLIC_BASE_URL=https://host on port 443")
        if not settings.get("ACME_EMAIL") or "@" not in settings["ACME_EMAIL"]:
            raise ValueError("ACME_EMAIL is required for server certificate issuance")
        if public.hostname == "localhost" or public.hostname.endswith((".local", ".internal", ".localhost")):
            raise ValueError("server HTTPS requires a public address or public DNS name")
        try:
            if not ipaddress.ip_address(public.hostname).is_global:
                raise ValueError("server HTTPS requires a public address or public DNS name")
        except ValueError as error:
            if "does not appear" not in str(error):
                raise
        if settings.get("TOKENLIBRARY_TEST_HOOKS", "0") != "0":
            raise ValueError("test-only administrative endpoints must be disabled on a server")
    elif public.scheme not in ("http", "https"):
        raise ValueError("PUBLIC_BASE_URL must use http or https")
    clock = settings.get("BACKUP_TIME", "03:00")
    if not re.fullmatch(r"(?:[01]\d|2[0-3]):[0-5]\d", clock):
        raise ValueError("BACKUP_TIME must be HH:MM")
    try:
        ZoneInfo(settings.get("BACKUP_TIMEZONE", "Asia/Shanghai"))
    except ZoneInfoNotFoundError:
        raise ValueError("BACKUP_TIMEZONE must be an installed IANA timezone") from None
    if not settings["ADMIN_PASSWORD_HASH"].startswith("$argon2id$"):
        raise ValueError("ADMIN_PASSWORD_HASH must be generated with make hashcred")
    if settings.get("UPLOAD_TOKEN_ENABLED", "true") == "true" and not re.fullmatch(r"(?:sha256:)?[0-9a-fA-F]{64}", settings.get("UPLOAD_TOKEN_HASH", "")):
        raise ValueError("UPLOAD_TOKEN_HASH must be a SHA-256 value when upload is enabled")
    for key in ("APP_UID", "APP_GID"):
        if not settings.get(key, "10001").isdigit() or int(settings.get(key, "10001")) == 0:
            raise ValueError(f"{key} must be a non-root numeric id")
    # Compose interpolates this into a URL; require URL-safe password characters.
    if not re.fullmatch(r"[A-Za-z0-9_.~-]+", settings["POSTGRES_PASSWORD"]):
        raise ValueError("POSTGRES_PASSWORD must use URL-safe letters, digits or _ . ~ -")
    if settings.get("APP_VERSION") and not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,3}", settings["APP_VERSION"]):
        raise ValueError("APP_VERSION must look like 1.0.0")
    if settings.get("APP_BUILD") and not re.fullmatch(r"[0-9]+", settings["APP_BUILD"]):
        raise ValueError("APP_BUILD must be a number")
    return data, backup, deployment

def wait_https(origin: str, timeout: float = 600) -> None:
    deadline = time.monotonic() + timeout
    print("Application ready; waiting for publicly trusted HTTPS (up to 10 minutes).", flush=True)
    while time.monotonic() < deadline:
        try:
            # Default TLS verification checks the hostname/IP and system certificate roots.
            with urlopen(origin.rstrip("/") + "/health/ready", timeout=5) as response:
                if response.status == 200 and response.url.startswith(origin.rstrip("/") + "/") and json.loads(response.read(4096)).get("ready") is True:
                    return
        except (OSError, ValueError):
            pass
        time.sleep(3)
    raise ValueError("HTTPS did not become trusted and ready; check Caddy logs, public DNS/address, ports 80/443 and ACME reachability")

def prepare_directories(data: Path, backup: Path, settings: dict[str, str], server: bool) -> None:
    uid, gid = int(settings.get("APP_UID", "10001")), int(settings.get("APP_GID", "10001"))
    data.mkdir(parents=True, exist_ok=True)
    def accessible(path: Path, permissions: int) -> bool:
        stat = path.stat()
        shift = 6 if stat.st_uid == uid else (3 if stat.st_gid == gid else 0)
        return (stat.st_mode >> shift) & permissions == permissions
    if not accessible(data, 1):
        raise ValueError("DATA_ROOT must be traversable by APP_UID/APP_GID")
    for path in (data / "files" / "objects", data / "files" / "staging", data / "runtime" / "app", backup):
        created = not path.exists()
        path.mkdir(parents=True, exist_ok=True, mode=0o750)
        if created and os.geteuid() == 0:
            os.chown(path, uid, gid)
        if path.resolve() != path:
            raise ValueError("application data subdirectories must not be symlinks")
        if not accessible(path, 3):
            raise ValueError(f"{path} must be writable by APP_UID/APP_GID; existing ownership was not changed")
    if server:
        for path in (data / "caddy" / "data", data / "caddy" / "config"):
            path.mkdir(parents=True, exist_ok=True)

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("start", "logs"))
    parser.add_argument("--mode", choices=("service", "middleware"), default="service")
    parser.add_argument("--env-file", type=Path, default=ROOT / ".env")
    args = parser.parse_args()
    settings = read_settings(args.env_file)
    deployment = settings.get("DEPLOYMENT", "local")
    if deployment not in ("local", "server"):
        raise ValueError("DEPLOYMENT must be local or server")
    environment = os.environ.copy()
    # Do not export literal secret values through a shell; Compose reads the original dotenv.
    host = urlsplit(settings.get("PUBLIC_BASE_URL", "")).hostname or "invalid.local"
    environment["TLS_HOST"] = f"[{host}]" if ":" in host else host
    compose_file = ROOT / "deploy" / ("compose.server.yaml" if deployment == "server" else "compose.yaml")
    compose = ["docker", "compose", "-p", "tokenlibrary", "--env-file", str(args.env_file), "-f", str(compose_file)]
    def run(*arguments: str, check: bool = True, quiet: bool = False) -> subprocess.CompletedProcess:
        return subprocess.run(compose + list(arguments), env=environment, check=check,
                              stdout=subprocess.DEVNULL if quiet else None,
                              stderr=subprocess.DEVNULL if quiet else None)
    services = ["postgres"] if args.mode == "middleware" else (["app", "caddy"] if deployment == "server" else ["app"])
    if args.action == "logs":
        run("logs", "-f", "--timestamps", "--tail=200", *services)
        return
    data, backup, deployment = validate(settings)
    run("config", "--quiet")
    prepare_directories(data, backup, settings, deployment == "server")
    if args.mode == "middleware":
        run("pull", "postgres")
    else:
        if run("exec", "-T", "postgres", "pg_isready", "-U", settings.get("POSTGRES_USER", "tokenlibrary"), "-d", settings.get("POSTGRES_DB", "tokenlibrary"), check=False, quiet=True).returncode:
            raise ValueError("PostgreSQL is not ready; run make start mode=middleware first")
        run("build", "app")
        if deployment == "server":
            run("pull", "caddy")
            run("run", "--rm", "--no-deps", "caddy", "caddy", "validate", "--config", "/etc/caddy/Caddyfile")
    # No old container is stopped until every required image/config has been prepared.
    run("up", "-d", "--no-deps", "--no-build", "--force-recreate", "--timeout", "30", *services)
    deadline = time.monotonic() + (60 if args.mode == "middleware" else 90)
    target = "postgres" if args.mode == "middleware" else "app"
    while time.monotonic() < deadline:
        check = ["pg_isready", "-U", settings.get("POSTGRES_USER", "tokenlibrary"), "-d", settings.get("POSTGRES_DB", "tokenlibrary")] if target == "postgres" else ["curl", "--fail", "--silent", "http://127.0.0.1:8080/health/ready"]
        if run("exec", "-T", target, *check, check=False, quiet=True).returncode == 0:
            if deployment == "server" and target == "app":
                wait_https(settings["PUBLIC_BASE_URL"])
            print(f"{args.mode} ready" + (" (HTTPS verified)" if deployment == "server" and target == "app" else ""))
            return
        time.sleep(1)
    raise ValueError("service did not become ready; inspect make logs (data directories were preserved)")

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Deployment failed: {error}", file=sys.stderr)
        sys.exit(1)
