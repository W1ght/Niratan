#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT_DIR/script/configure_hoshi_google_signin.py" <<'PY'
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile

helper = Path(sys.argv[1])
client_id = "123-release-fixture.apps.googleusercontent.com"
secret = "SYNTHETIC-secret-never-a-real-credential"
base_environment = dict(os.environ)
for key in ("HOSHI_READER_GOOGLE_CLIENT_ID", "HOSHI_READER_GOOGLE_CLIENT_SECRET"):
    base_environment.pop(key, None)
checks = 0

def execute(arguments, values=None, success=True):
    global checks
    environment = dict(base_environment)
    environment.update(values or {})
    result = subprocess.run([sys.executable, str(helper), *arguments], env=environment, text=True, capture_output=True)
    assert (result.returncode == 0) == success, "configuration operation returned the wrong status"
    assert client_id not in result.stdout + result.stderr, "helper printed its client ID"
    assert secret not in result.stdout + result.stderr, "helper printed its secret"
    checks += 1
    return result

with tempfile.TemporaryDirectory(prefix="niratan-google-release-contract-") as directory:
    root = Path(directory)
    config = root / "private.xcconfig"
    values = {"HOSHI_READER_GOOGLE_CLIENT_ID": client_id, "HOSHI_READER_GOOGLE_CLIENT_SECRET": secret}
    execute(["--output", str(config)], values)
    assert config.read_text() == f"HOSHI_READER_GOOGLE_CLIENT_ID = {client_id}\nHOSHI_READER_GOOGLE_CLIENT_SECRET = {secret}\n"
    assert stat.S_IMODE(config.stat().st_mode) == 0o600
    checks += 2
    execute(["--output", str(config)], {"HOSHI_READER_GOOGLE_CLIENT_ID": client_id})
    assert config.read_text().endswith("HOSHI_READER_GOOGLE_CLIENT_SECRET = \n")
    checks += 1
    for invalid in [None, "$(MISSING_CLIENT)", client_id + "\nOTHER_SETTING = injected", "not-a-google-client"]:
        environment = {} if invalid is None else {"HOSHI_READER_GOOGLE_CLIENT_ID": invalid}
        destination = root / "invalid.xcconfig"
        execute(["--output", str(destination)], environment, success=False)
        assert not destination.exists()
        checks += 1
    for invalid_secret in ["$(MISSING_SECRET)", "unsafe\nOTHER_SETTING = injected", "unsafe // comment"]:
        execute(["--output", str(root / "unsafe.xcconfig")], {"HOSHI_READER_GOOGLE_CLIENT_ID": client_id, "HOSHI_READER_GOOGLE_CLIENT_SECRET": invalid_secret}, success=False)
        assert not (root / "unsafe.xcconfig").exists()
        checks += 1

    bundle = root / "Fixture.app"
    info = bundle / "Contents/Info.plist"
    info.parent.mkdir(parents=True)
    def write_info(identifier=client_id, configured_secret=secret):
        data = {"HoshiReaderGoogleClientID": identifier}
        if configured_secret is not None:
            data["HoshiReaderGoogleClientSecret"] = configured_secret
        info.write_bytes(plistlib.dumps(data))
    write_info()
    execute(["--verify-bundle", str(bundle)])
    execute(["--verify-bundle", str(bundle)], values)
    execute(["--verify-bundle", str(bundle)], {"HOSHI_READER_GOOGLE_CLIENT_ID": "456-other-fixture.apps.googleusercontent.com"}, success=False)
    execute(["--verify-bundle", str(bundle)], {"HOSHI_READER_GOOGLE_CLIENT_SECRET": "different-synthetic-secret"}, success=False)
    write_info(configured_secret=None)
    execute(["--verify-bundle", str(bundle)], {"HOSHI_READER_GOOGLE_CLIENT_ID": client_id, "HOSHI_READER_GOOGLE_CLIENT_SECRET": ""})
    for identifier, configured_secret in [("", secret), ("$(MISSING_CLIENT)", secret), (client_id, "$(MISSING_SECRET)")]:
        write_info(identifier, configured_secret)
        execute(["--verify-bundle", str(bundle)], success=False)
    info.write_bytes(plistlib.dumps(["not a dictionary"]))
    execute(["--verify-bundle", str(bundle)], success=False)
    info.write_bytes(b"malformed property list")
    execute(["--verify-bundle", str(bundle)], success=False)
    execute(["--verify-bundle", str(root / "Missing.app")], success=False)

print(f"PASS Hoshi Google sign-in release configuration: {checks} checks; synthetic values only")
PY
