#!/usr/bin/env python3
"""Create private Google sign-in build settings or verify the built app's settings."""

import argparse
import os
from pathlib import Path
import plistlib
import re
import sys
import tempfile


CLIENT_ID_KEY = "HOSHI_READER_GOOGLE_CLIENT_ID"
CLIENT_SECRET_KEY = "HOSHI_READER_GOOGLE_CLIENT_SECRET"
CLIENT_ID_PATTERN = re.compile(r"[0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com")
SECRET_PATTERN = re.compile(r"[A-Za-z0-9_-]+")


class ConfigurationError(ValueError):
    pass


def validate_client_id(value):
    if not isinstance(value, str) or not CLIENT_ID_PATTERN.fullmatch(value):
        raise ConfigurationError("Hoshi Reader Google client ID is missing or invalid.")
    return value


def validate_secret(value):
    # Native OAuth clients may omit a secret. A configured value must remain one
    # literal xcconfig setting: reject expansion, comments and newlines.
    if not isinstance(value, str) or (value and not SECRET_PATTERN.fullmatch(value)):
        raise ConfigurationError("Hoshi Reader Google client secret is not a safe literal value.")
    return value


def configure(output):
    client_id = validate_client_id(os.environ.get(CLIENT_ID_KEY, ""))
    secret = validate_secret(os.environ.get(CLIENT_SECRET_KEY, ""))
    content = f"{CLIENT_ID_KEY} = {client_id}\n{CLIENT_SECRET_KEY} = {secret}\n"
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".hoshi-google-signin-", dir=output.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as file:
            file.write(content)
        os.chmod(temporary, 0o600)
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print("Configured private Hoshi Reader Google sign-in build settings.")


def verify_bundle(bundle):
    with (Path(bundle) / "Contents/Info.plist").open("rb") as file:
        info = plistlib.load(file)
    if not isinstance(info, dict):
        raise ConfigurationError("Built app metadata is not a property-list dictionary.")
    client_id = validate_client_id(info.get("HoshiReaderGoogleClientID", ""))
    secret = validate_secret(info.get("HoshiReaderGoogleClientSecret", ""))
    # The CI build supplies the same values as the configuration step. Checking
    # them here catches omitted build-setting expansion or stale bundle metadata.
    if CLIENT_ID_KEY in os.environ:
        expected_id = validate_client_id(os.environ[CLIENT_ID_KEY])
        if client_id != expected_id:
            raise ConfigurationError("Built Google client ID does not match the release configuration.")
    if CLIENT_SECRET_KEY in os.environ:
        expected_secret = validate_secret(os.environ[CLIENT_SECRET_KEY])
        if secret != expected_secret:
            raise ConfigurationError("Built Google client secret does not match the release configuration.")
    print("Verified the built app's Hoshi Reader Google sign-in configuration.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group(required=True)
    operation.add_argument("--output", help="Write a private xcconfig from the release environment.")
    operation.add_argument("--verify-bundle", help="Verify the final built .app without printing configuration values.")
    arguments = parser.parse_args()
    try:
        if arguments.output:
            configure(arguments.output)
        else:
            verify_bundle(arguments.verify_bundle)
    except ConfigurationError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except (OSError, ValueError, plistlib.InvalidFileException):
        print("ERROR: Could not read or write the Google sign-in configuration file.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
