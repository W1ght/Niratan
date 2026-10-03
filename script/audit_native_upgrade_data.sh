#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/Library/Application Support"
DEFAULTS_DOMAIN="moe.shishamo.hoshi"
CHECK_DEFAULTS=1
CHECK_KEYCHAIN=1

usage() {
  cat <<'EOF'
usage: script/audit_native_upgrade_data.sh [--root DIR] [--skip-defaults] [--skip-keychain]

Performs a read-only audit of Niratan upgrade data. Output contains only
counts and presence states; it never prints stored values, book names, or tokens.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || {
        echo "--root requires a directory" >&2
        exit 2
      }
      ROOT="$2"
      shift 2
      ;;
    --skip-defaults)
      CHECK_DEFAULTS=0
      shift
      ;;
    --skip-keychain)
      CHECK_KEYCHAIN=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ -d "$ROOT" ]] || {
  echo "Application Support root is missing" >&2
  exit 1
}

python3 - "$ROOT" <<'PY'
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
books = root / "Books"
dictionaries = root / "Dictionaries"

book_metadata = list(books.glob("*/metadata.json")) if books.is_dir() else []
dictionary_indexes = list(dictionaries.glob("*/*/index.json")) if dictionaries.is_dir() else []

sidecar_names = {
    "metadata.json",
    "bookmark.json",
    "bookinfo.json",
    "statistics.json",
    "statistics_sessions.json",
    "sasayaki_match.json",
    "sasayaki_playback.json",
    "highlights.json",
}
json_paths = []
if books.is_dir():
    json_paths.extend(
        path
        for path in books.glob("*/*.json")
        if path.name in sidecar_names
    )
if dictionaries.is_dir():
    config = dictionaries / "config.json"
    if config.is_file():
        json_paths.append(config)
    json_paths.extend(dictionary_indexes)
for name in ("anki_config.json", "anki_words.json"):
    path = root / name
    if path.is_file():
        json_paths.append(path)

invalid_json = 0
for path in json_paths:
    try:
        with path.open("r", encoding="utf-8") as handle:
            json.load(handle)
    except (OSError, UnicodeError, json.JSONDecodeError):
        invalid_json += 1

print(f"books: {len(book_metadata)}")
print(f"dictionaries: {len(dictionary_indexes)}")
print(f"json files checked: {len(json_paths)}")
print(f"invalid json: {invalid_json}")

if invalid_json:
    sys.exit(1)
PY

if (( CHECK_DEFAULTS )); then
  if defaults read "$DEFAULTS_DOMAIN" >/dev/null 2>&1; then
    echo "user defaults: present"
  else
    echo "user defaults: absent"
  fi
fi

if (( CHECK_KEYCHAIN )); then
  for account in accessToken refreshToken clientId; do
    if security find-generic-password \
      -a "$account" >/dev/null 2>&1; then
      echo "keychain $account: present"
    else
      echo "keychain $account: absent-or-inaccessible"
    fi
  done
fi

echo "Native upgrade data audit passed"
