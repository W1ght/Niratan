#!/usr/bin/env bash
# Runs every script/test_* check and prints a PASS/FAIL/SKIP summary.
#
# usage: script/run_tests.sh [name-filter]
#
# Directives read from the top of a script/test_*.swift file:
#   // test-sources: <repo-relative .swift files compiled with the test>
#                    (may be empty: an @main test compiled on its own)
#   // test-modules: <SwiftPM modules linked from an existing Xcode build>
#   // test-skip: <reason>   (needs the full app target, or is a manual tool)
# A test without directives is a source contract run by the Swift interpreter.
# script/test_*.sh files may declare `# test-requires-path: <repo path>`; they are
# skipped (not failed) when that bootstrap output is missing.
# Module tests use HOSHI_TEST_PRODUCTS, or the newest .build/xcode-derived-data*
# Debug products; they are skipped when no build exists.
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
FILTER="${1:-}"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/niratan-tests.XXXXXX")"
LOG_DIR="$ROOT_DIR/.build/test-logs"
rm -rf "$LOG_DIR"
trap 'rm -rf "$WORK_DIR"' EXIT
export CLANG_MODULE_CACHE_PATH="$WORK_DIR/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$WORK_DIR/swift-module-cache"

PRODUCTS="${HOSHI_TEST_PRODUCTS:-}"
if [[ -z "$PRODUCTS" ]]; then
  PRODUCTS="$(ls -dt .build/xcode-derived-data*/Build/Products/Debug 2>/dev/null | head -n 1)"
fi
MODULE_MAPS=""
if [[ -n "$PRODUCTS" ]]; then
  MODULE_MAPS="$(cd "$PRODUCTS/../../Intermediates.noindex/GeneratedModuleMaps" 2>/dev/null && pwd)"
fi

directive() {
  sed -n "s|^// $1: *||p" "$2" | tr '\n' ' '
}

PASSED=()
FAILED=()
SKIPPED=()

record() {
  local status="$1" name="$2" detail="${3:-}"
  printf '%-5s %s%s\n' "$status" "$name" "${detail:+  ($detail)}"
  case "$status" in
    PASS) PASSED+=("$name") ;;
    FAIL)
      FAILED+=("$name")
      mkdir -p "$LOG_DIR"
      cp "$WORK_DIR/$name.log" "$LOG_DIR/" 2>/dev/null
      ;;
    SKIP) SKIPPED+=("$name") ;;
  esac
}

run_swift_test() {
  local file="$1" name
  name="$(basename "$file" .swift)"
  local skip sources modules log="$WORK_DIR/$name.log"
  skip="$(directive test-skip "$file")"
  if [[ -n "$skip" ]]; then
    record SKIP "$name" "$skip"
    return
  fi
  sources="$(directive test-sources "$file")"
  modules="$(directive test-modules "$file")"
  if ! grep -q '^// test-sources:' "$file" && [[ -z "$modules" ]]; then
    if xcrun swift "$file" >"$log" 2>&1; then
      record PASS "$name"
    else
      record FAIL "$name" "$(grep -m1 -E 'FAIL|error:' "$log" | cut -c1-160)"
    fi
    return
  fi

  local flags=()
  if [[ -n "$modules" ]]; then
    if [[ -z "$PRODUCTS" ]]; then
      record SKIP "$name" "needs an Xcode build for: $modules"
      return
    fi
    flags+=(-I "$PRODUCTS")
    local map module include
    for map in "$MODULE_MAPS"/*.modulemap; do
      [[ -f "$map" ]] && flags+=(-Xcc "-fmodule-map-file=$map")
    done
    # C targets' public headers, which the generated module maps refer to.
    for include in .build/source-packages/checkouts/*/Sources/*/include Libraries/*/Sources/*/include; do
      [[ -d "$include" ]] && flags+=(-Xcc -I -Xcc "$include")
    done
    for module in $modules; do
      flags+=("$PRODUCTS/$module.o")
    done
  fi
  # shellcheck disable=SC2086
  if ! xcrun swiftc -parse-as-library -suppress-warnings -enable-bare-slash-regex ${flags[@]+"${flags[@]}"} $sources "$file" \
      -o "$WORK_DIR/$name" >"$log" 2>&1; then
    record FAIL "$name" "compile: $(grep -m1 'error:' "$log" | cut -c1-140)"
    return
  fi
  if "$WORK_DIR/$name" >"$log" 2>&1; then
    record PASS "$name"
  else
    record FAIL "$name" "$(tail -n 1 "$log" | cut -c1-160)"
  fi
}

for file in script/test_*.swift; do
  [[ -n "$FILTER" && "$file" != *"$FILTER"* ]] && continue
  run_swift_test "$file"
done
for file in script/test_*.sh; do
  [[ -n "$FILTER" && "$file" != *"$FILTER"* ]] && continue
  name="$(basename "$file")"
  required="$(sed -n 's|^# test-requires-path: *||p' "$file" | head -n 1)"
  if [[ -n "$required" && ! -e "$required" ]]; then
    record SKIP "$name" "missing $required (run its bootstrap script first)"
    continue
  fi
  if bash "$file" >"$WORK_DIR/$name.log" 2>&1; then
    record PASS "$name"
  else
    record FAIL "$name" "$(tail -n 1 "$WORK_DIR/$name.log" | cut -c1-160)"
  fi
done

echo
echo "${#PASSED[@]} passed, ${#FAILED[@]} failed, ${#SKIPPED[@]} skipped"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  printf 'failed: %s\n' "${FAILED[@]}"
  echo "logs: $LOG_DIR"
  exit 1
fi
