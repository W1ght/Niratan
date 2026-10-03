#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Niratan"
EXPECTED_BUNDLE_ID="moe.shishamo.hoshi"
PROJECT_NAME="Niratan.xcodeproj"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTANCE_ID="${HOSHI_APP_INSTANCE_ID:-}"
DERIVED_DATA_PATH="${HOSHI_DERIVED_DATA_PATH:-}"
SOURCE_PACKAGES_PATH="${HOSHI_SOURCE_PACKAGES_PATH:-}"
APP_BUNDLE=""
APP_EXECUTABLE=""
MODE="run"
MODE_ARGS=()
OPEN_ENV_ARGS=()
DATA_ROOT="${HOSHI_DATA_ROOT:-}"
SYSTEM_APPEARANCE="${HOSHI_DEBUG_SYSTEM_APPEARANCE:-}"

usage() {
  cat <<'EOF'
usage: build_and_run_native.sh [--instance <id>] [--data-root <dir>] [--appearance dark|light] [mode] [arguments]

Niratan has one full-feature build containing Reader and Video.

isolation:
  --instance <id>         Use .build/xcode-derived-data-<id> so parallel sessions target distinct app bundles.
                          HOSHI_DERIVED_DATA_PATH still takes precedence when set.
                          Old inactive instance builds are pruned automatically.
  --data-root <dir>       Keep all user data (defaults, Application Support, Keychain items)
                          under <dir> instead of sharing the installed app's data.

debugging:
  --appearance dark|light Stand in for the system appearance (follow-system themes only).

modes:
  run                     Build and launch.
  --clean                 Remove inactive repo-local build and release artifacts.
  --open-latest           Launch the latest existing build without rebuilding.
  --open-url <url>        Build, launch, and open a Hoshi URL.
  --debug                 Build and attach LLDB.
  --logs                  Build, launch, and stream logs.
  --telemetry             Build, launch, and stream logs.
  --verify                Build, launch, and verify the process started.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --light|--video)
      echo "$1 was removed; Niratan now has one full-feature build." >&2
      usage >&2
      exit 2
      ;;
    --instance)
      if [[ $# -lt 2 ]]; then
        echo "--instance requires an id" >&2
        usage >&2
        exit 2
      fi
      INSTANCE_ID="$2"
      shift 2
      ;;
    --data-root)
      if [[ $# -lt 2 ]]; then
        echo "--data-root requires a directory" >&2
        usage >&2
        exit 2
      fi
      DATA_ROOT="$2"
      shift 2
      ;;
    --appearance)
      if [[ $# -lt 2 || ! "$2" =~ ^(dark|light)$ ]]; then
        echo "--appearance requires dark or light" >&2
        usage >&2
        exit 2
      fi
      SYSTEM_APPEARANCE="$2"
      shift 2
      ;;
    run|--clean|clean|--open-latest|open-latest|--open-url|open-url|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
      MODE="$1"
      shift
      MODE_ARGS=("$@")
      break
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

SCHEME_NAME="Niratan"
CONFIGURATION="Debug"

if [[ -n "$INSTANCE_ID" && ! "$INSTANCE_ID" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "--instance may only contain letters, numbers, '.', '_' and '-'" >&2
  exit 2
fi

if [[ -z "$DERIVED_DATA_PATH" ]]; then
  if [[ -n "$INSTANCE_ID" ]]; then
    DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode-derived-data-$INSTANCE_ID"
  else
    DERIVED_DATA_PATH="$ROOT_DIR/.build/xcode-derived-data"
  fi
fi

if [[ -z "$SOURCE_PACKAGES_PATH" ]]; then
  SOURCE_PACKAGES_PATH="$ROOT_DIR/.build/xcode-source-packages"
fi

cd "$ROOT_DIR"

matching_app_pids() {
  resolve_app_bundle
  local pid
  local command
  while IFS= read -r pid; do
    if [[ -z "$pid" ]]; then
      continue
    fi
    command="$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null || true)"
    if [[ "$command" == "$APP_EXECUTABLE"* ]]; then
      printf '%s\n' "$pid"
    fi
  done < <(LC_ALL=C pgrep -f -- "$APP_EXECUTABLE" || true)
}

kill_app() {
  local pid
  local killed=0

  while IFS= read -r pid; do
    if [[ -z "$pid" ]]; then
      continue
    fi
    kill "$pid" >/dev/null 2>&1 || true
    killed=1
  done < <(matching_app_pids)

  if [[ "$killed" -eq 1 ]]; then
    for _ in {1..40}; do
      if [[ -z "$(running_app_pid || true)" ]]; then
        return 0
      fi
      sleep 0.1
    done
  fi
}

build_app() {
  bash "$ROOT_DIR/script/cleanup_build_artifacts.sh" --prune --protect "$DERIVED_DATA_PATH"
  local svt_architectures=""
  if [[ -f "$ROOT_DIR/Vendor/libmpv/lib/libSvtAv1Enc.4.dylib" ]]; then
    svt_architectures="$(lipo -archs "$ROOT_DIR/Vendor/libmpv/lib/libSvtAv1Enc.4.dylib" 2>/dev/null || true)"
  fi
  if [[ ! -f "$ROOT_DIR/Vendor/libmpv/lib/libmpv.2.dylib" \
    || ! -f "$ROOT_DIR/Vendor/libmpv/lib/libSvtAv1Enc.4.dylib" \
    || "$svt_architectures" != *arm64* \
    || "$svt_architectures" != *x86_64* ]]; then
    bash "$ROOT_DIR/script/bootstrap_video_dependencies.sh"
  fi
  xcodebuild \
    -quiet \
    -project "$PROJECT_NAME" \
    -scheme "$SCHEME_NAME" \
    -configuration "$CONFIGURATION" \
    -sdk macosx \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build
}

resolve_app_bundle() {
  APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/$APP_NAME.app"
  APP_EXECUTABLE="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
}

running_app_pid() {
  matching_app_pids | head -n 1
}

wait_for_running_app() {
  local pid=""
  for _ in {1..40}; do
    pid="$(running_app_pid || true)"
    if [[ -n "$pid" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.1
  done
  echo "Expected app executable did not start: $APP_EXECUTABLE" >&2
  return 1
}

open_app() {
  if [[ $# -gt 0 ]]; then
    open_with_env -n "$APP_BUNDLE" --args "$@"
    wait_for_running_app >/dev/null
    open_with_env "$APP_BUNDLE"
  else
    open_with_env -n "$APP_BUNDLE"
  fi
}

open_url() {
  local url="$1"
  open_with_env -a "$APP_BUNDLE" "$url"
}

if [[ -n "$DATA_ROOT" ]]; then
  mkdir -p "$DATA_ROOT/Home"
  DATA_ROOT="$(cd "$DATA_ROOT" && pwd)"
  # The app refuses to start unless both point at the same isolated root.
  export HOSHI_DATA_ROOT="$DATA_ROOT"
  export CFFIXED_USER_HOME="$DATA_ROOT/Home"
fi
if [[ -n "$SYSTEM_APPEARANCE" ]]; then
  export HOSHI_DEBUG_SYSTEM_APPEARANCE="$SYSTEM_APPEARANCE"
fi

open_env_args() {
  OPEN_ENV_ARGS=()
  local name
  for name in HOSHI_DATA_ROOT CFFIXED_USER_HOME HOSHI_DEBUG_SYSTEM_APPEARANCE; do
    if [[ -n "${!name:-}" ]]; then
      OPEN_ENV_ARGS+=(--env "$name=${!name}")
    fi
  done
  if [[ -n "${HOSHI_VIDEO_LIBRARY_CATALOG_URL:-}" ]]; then
    OPEN_ENV_ARGS+=(--env "HOSHI_VIDEO_LIBRARY_CATALOG_URL=$HOSHI_VIDEO_LIBRARY_CATALOG_URL")
  fi
  if [[ -n "${HOSHI_MANGA_LIBRARY_CATALOG_URL:-}" ]]; then
    OPEN_ENV_ARGS+=(--env "HOSHI_MANGA_LIBRARY_CATALOG_URL=$HOSHI_MANGA_LIBRARY_CATALOG_URL")
  fi
}

open_with_env() {
  open_env_args
  if [[ ${#OPEN_ENV_ARGS[@]} -gt 0 ]]; then
    /usr/bin/open "${OPEN_ENV_ARGS[@]}" "$@"
  else
    /usr/bin/open "$@"
  fi
}

verify_bundle() {
  resolve_app_bundle
  if [[ -z "$APP_BUNDLE" || ! -d "$APP_BUNDLE" ]]; then
    echo "Expected native macOS app bundle not found at: $APP_BUNDLE" >&2
    exit 1
  fi

  local bundle_identifier
  bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$bundle_identifier" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "Built app bundle identifier mismatch: expected $EXPECTED_BUNDLE_ID, got $bundle_identifier." >&2
    exit 1
  fi
  if [[ ! -x "$APP_EXECUTABLE" ]]; then
    echo "Expected app executable not found: $APP_EXECUTABLE" >&2
    exit 1
  fi
}

local_debug_codesign_identity() {
  local identity
  identity="$(
    security find-identity -v -p codesigning 2>/dev/null \
      | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
      | head -n 1
  )"
  if [[ -n "$identity" ]]; then
    printf '%s\n' "$identity"
  else
    printf '%s\n' "-"
  fi
}

codesign_local_debug_bundle() {
  if [[ -z "$APP_BUNDLE" || ! -d "$APP_BUNDLE" ]]; then
    return
  fi

  local signing_identity
  signing_identity="$(local_debug_codesign_identity)"

  local item
  while IFS= read -r item; do
    chmod u+w "$item" 2>/dev/null || true
    codesign --force --sign "$signing_identity" "$item" >/dev/null 2>&1
  done < <(
    find \
      "$APP_BUNDLE/Contents/MacOS" \
      "$APP_BUNDLE/Contents/Frameworks" \
      -type f -name '*.dylib' \
      2>/dev/null \
      | sort -u
  )
  while IFS= read -r item; do
    chmod u+w "$item" 2>/dev/null || true
    codesign --force --sign "$signing_identity" "$item" >/dev/null 2>&1
  done < <(
    find \
      "$APP_BUNDLE/Contents/MacOS" \
      "$APP_BUNDLE/Contents/Frameworks" \
      -type f ! -name '*.dylib' -perm -111 \
      2>/dev/null \
      | sort -u
  )
  codesign --force --sign "$signing_identity" "$APP_BUNDLE" >/dev/null 2>&1
  codesign --verify --deep --strict "$APP_BUNDLE"
  if [[ "$signing_identity" != "-" ]]; then
    sleep 1
  fi
}

refresh_app_icon_registration() {
  /usr/bin/touch "$APP_BUNDLE" "$APP_BUNDLE/Contents" "$APP_BUNDLE/Contents/Info.plist"
  if [[ -f "$APP_BUNDLE/Contents/Resources/HoshiIcon.icns" ]]; then
    /usr/bin/touch "$APP_BUNDLE/Contents/Resources/HoshiIcon.icns"
  fi

  local lsregister="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$lsregister" ]]; then
    "$lsregister" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
  fi
}

case "$MODE" in
  run)
    kill_app
    build_app
    verify_bundle
    codesign_local_debug_bundle
    refresh_app_icon_registration
    open_app
    ;;
  --clean|clean)
    kill_app
    bash "$ROOT_DIR/script/cleanup_build_artifacts.sh" --all
    ;;
  --open-latest|open-latest)
    kill_app
    verify_bundle
    codesign_local_debug_bundle
    refresh_app_icon_registration
    open_app
    ;;
  --open-url|open-url)
    if [[ ${#MODE_ARGS[@]} -ne 1 ]]; then
      echo "usage: $0 --open-url <url>" >&2
      exit 2
    fi
    kill_app
    build_app
    verify_bundle
    codesign_local_debug_bundle
    refresh_app_icon_registration
    open_url "${MODE_ARGS[0]}"
    wait_for_running_app >/dev/null
    ;;
  --debug|debug)
    kill_app
    build_app
    verify_bundle
    codesign_local_debug_bundle
    refresh_app_icon_registration
    lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    kill_app
    build_app
    verify_bundle
    codesign_local_debug_bundle
    refresh_app_icon_registration
    open_app
    LOG_PID="$(wait_for_running_app)"
    /usr/bin/log stream --info --style compact --predicate "processIdentifier == $LOG_PID"
    ;;
  --telemetry|telemetry)
    kill_app
    build_app
    verify_bundle
    codesign_local_debug_bundle
    refresh_app_icon_registration
    open_app
    LOG_PID="$(wait_for_running_app)"
    /usr/bin/log stream --info --style compact --predicate "processIdentifier == $LOG_PID"
    ;;
  --verify|verify)
    kill_app
    build_app
    verify_bundle
    codesign_local_debug_bundle
    refresh_app_icon_registration
    open_app
    VERIFIED_PID="$(wait_for_running_app)"
    echo "Verified $EXPECTED_BUNDLE_ID at $APP_BUNDLE (pid $VERIFIED_PID)"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
