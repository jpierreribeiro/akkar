"""Opt-in disruptions, restricted to an explicitly named disposable Compose project."""
import argparse
import json
import subprocess
import time
import uuid
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("project", help="must start with akkar-consolidation-")
    args = parser.parse_args()
    if not args.project.startswith("akkar-consolidation-"):
        parser.error("only an explicitly named disposable consolidation project is allowed")
    manifest = str(Path(__file__).with_name("docker-compose.yml"))
    compose = ["docker", "compose", "--project-name", args.project, "-f", manifest]

    def run(*arguments, **kwargs):
        return subprocess.run([*compose, *arguments], check=True, **kwargs)

    # Resolve every target and verify ownership before the first stop.
    containers = {}
    for service in ("api", "worker", "dispatcher", "postgres", "redis"):
        container = run("ps", "-q", service, capture_output=True, text=True).stdout.strip()
        if not container:
            raise RuntimeError(f"missing running {service}")
        label = subprocess.check_output(["docker", "inspect", "--format",
            '{{index .Config.Labels "com.docker.compose.project"}}', container], text=True).strip()
        if label != args.project:
            raise RuntimeError("container ownership mismatch")
        containers[service] = container

    def control(action, service):
        # Compose start may restart one-shot dependencies (including migrations).
        # Act only on the exact container whose ownership was checked above.
        subprocess.run(["docker", action, containers[service]], check=True)

    def smoke():
        run("exec", "-T", "api", "/app/.venv/bin/python", "smoke.py", timeout=150)

    smoke()
    passed = []
    for service in ("dispatcher", "redis", "worker"):
        control("stop", service)
        probe = None
        try:
            probe = subprocess.Popen([*compose, "exec", "-T", "api",
                                      "/app/.venv/bin/python", "smoke.py"])
            time.sleep(5)
        finally:
            control("start", service)
        if probe is None or probe.wait(timeout=150) != 0:
            raise RuntimeError(f"batch failed after {service} recovery")
        passed.append(service)

    # Do not claim an in-flight fault proof for these restart smoke checks.
    for service in ("postgres", "api"):
        control("restart", service)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            check = subprocess.run([*compose, "exec", "-T", "api", "/app/.venv/bin/python", "-c",
                "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/ready', timeout=5)"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if check.returncode == 0:
                break
            time.sleep(2)
        else:
            raise RuntimeError(f"readiness did not recover after {service}")
        smoke()
        passed.append(service)
    # A database-only restore proof. It does not claim object-store disaster
    # recovery or that original S3 VersionIds survive an operator's backup tool.
    pg = containers["postgres"]
    restored = "akkar_restore_" + uuid.uuid4().hex
    dump = subprocess.check_output(["docker", "exec", pg, "pg_dump", "-U", "akkar",
                                    "-d", "akkar_ml", "-Fc"], timeout=60)
    expected = subprocess.check_output(["docker", "exec", pg, "psql", "-U", "akkar",
        "-d", "akkar_ml", "-Atc", "select count(*) from ml_batch_jobs"], text=True).strip()
    subprocess.run(["docker", "exec", pg, "createdb", "-U", "akkar", restored], check=True)
    try:
        subprocess.run(["docker", "exec", "-i", pg, "pg_restore", "-U", "akkar",
                        "-d", restored, "--exit-on-error"], input=dump, check=True, timeout=90)
        actual = subprocess.check_output(["docker", "exec", pg, "psql", "-U", "akkar",
            "-d", restored, "-Atc", "select count(*) from ml_batch_jobs"], text=True).strip()
        if actual != expected:
            raise RuntimeError("restored job count differs")
    finally:
        # Only the uniquely named database this invocation just created.
        subprocess.run(["docker", "exec", pg, "dropdb", "-U", "akkar", restored], check=True)
    print(json.dumps({"ok": True, "recovered": passed,
                      "database_restore_rows": int(expected),
                      "scope": "local dependency restart smoke, not production certification"}))


if __name__ == "__main__":
    main()
