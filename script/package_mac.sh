#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <version>" >&2
  echo "example: $0 0.6.0" >&2
  exit 2
fi

VERSION="$1"
APP_VERSION="${VERSION%%-*}"
if [[ "$VERSION" =~ ^([0-9]+\.[0-9]+\.[0-9]+)beta[0-9]+$ ]]; then
  APP_VERSION="${BASH_REMATCH[1]}"
fi
APP_NAME="Niratan"
EXPECTED_BUNDLE_ID="moe.shishamo.hoshi"
PROJECT_NAME="Niratan.xcodeproj"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_DIR="$ROOT_DIR/release"
SIGNING_IDENTITY="${HOSHI_RELEASE_SIGNING_IDENTITY:--}"

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ \
  && ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+beta[0-9]+$ ]]; then
  echo "Invalid release version: $VERSION" >&2
  exit 2
fi

SCHEME_NAME="Niratan"
CONFIGURATION="Release"
ARTIFACT_NAME="Niratan-Mac-$VERSION"
BUILD_DIR="$RELEASE_DIR/DerivedData"
STAGING_DIR="$RELEASE_DIR/$ARTIFACT_NAME"
DMG_PATH="$RELEASE_DIR/$ARTIFACT_NAME.dmg"
CHECKSUM_PATH="$RELEASE_DIR/$ARTIFACT_NAME.sha256"

cd "$ROOT_DIR"

bash script/bootstrap_video_dependencies.sh

xcodebuild \
  -quiet \
  -project "$PROJECT_NAME" \
  -scheme "$SCHEME_NAME" \
  -configuration "$CONFIGURATION" \
  -sdk macosx \
  -derivedDataPath "$BUILD_DIR" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

APP_BUNDLE="$BUILD_DIR/Build/Products/$CONFIGURATION/$APP_NAME.app"
if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "Release app bundle not found." >&2
  exit 1
fi

INFO_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
if [[ "$INFO_VERSION" != "$APP_VERSION" ]]; then
  echo "Built app version mismatch: expected $APP_VERSION, got $INFO_VERSION." >&2
  exit 1
fi

INFO_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_BUNDLE/Contents/Info.plist")"
if [[ "$INFO_BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
  echo "Built app bundle identifier mismatch: expected $EXPECTED_BUNDLE_ID, got $INFO_BUNDLE_ID." >&2
  exit 1
fi

if [[ ! -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ]]; then
  echo "Built app executable is missing: $APP_BUNDLE/Contents/MacOS/$APP_NAME" >&2
  exit 1
fi

verify_full_bundle() {
  local frameworks="$APP_BUNDLE/Contents/Frameworks"
  local youtube_resources="$APP_BUNDLE/Contents/Resources/YouTubeKit_YouTubeKit.bundle"
  local main_executable="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
  [[ -f "$frameworks/libmpv.2.dylib" ]] || {
    echo "Full app is missing libmpv." >&2
    exit 1
  }
  [[ -f "$frameworks/libSvtAv1Enc.4.dylib" ]] || {
    echo "Full app is missing the SVT-AV1 encoder." >&2
    exit 1
  }
  [[ -d "$youtube_resources" ]] || {
    echo "Full app is missing YouTubeKit resources." >&2
    exit 1
  }

  local nested_code_bundles
  nested_code_bundles="$(
    find "$APP_BUNDLE" -mindepth 1 \
      \( -iname '*.app' -o -iname '*.xpc' -o -iname '*.appex' \) \
      -print
  )"
  [[ -z "$nested_code_bundles" ]] || {
    echo "Full app contains a prohibited nested code bundle: $nested_code_bundles" >&2
    exit 1
  }

  local prohibited_runtime_payloads
  prohibited_runtime_payloads="$(
    find "$APP_BUNDLE" \
      \( \
        -iname '*AidokuRunner*' \
        -o -iname '*Shinsou*' \
        -o -iname '*.apk' \
        -o -iname '*.jar' \
        -o -iname '*.class' \
        -o -iname '*.dex' \
        -o -iname '*jre*' \
        -o -iname '*jvm*' \
        -o -iname 'jdk' \
        -o -iname 'jdk-*' \
        -o -iname '*.jdk' \
        -o -iname 'java' \
        -o -iname 'java.exe' \
        -o -iname 'JavaVM.framework' \
        -o -iname 'JavaRuntimeSupport.framework' \
      \) \
      -print
  )"
  [[ -z "$prohibited_runtime_payloads" ]] || {
    echo "Full app contains a prohibited runtime payload: $prohibited_runtime_payloads" >&2
    exit 1
  }

  local candidate
  local file_description
  while IFS= read -r -d '' candidate; do
    # Versioned frameworks (onnxruntime.framework) link Resources and Versions/Current to directories.
    [[ -d "$candidate" ]] && continue
    file_description="$(LC_ALL=C file -Lb "$candidate")"
    if [[ "$file_description" == *Mach-O* ]]; then
      if otool -hv "$candidate" 2>/dev/null \
        | grep -E '(^|[[:space:]])EXECUTE([[:space:]]|$)' >/dev/null \
        && [[ "$candidate" != "$main_executable" ]]; then
        echo "Full app contains an unexpected Mach-O helper executable: $candidate" >&2
        exit 1
      fi
    elif [[ -x "$candidate" ]]; then
      echo "Full app contains an unexpected executable helper payload: $candidate" >&2
      exit 1
    fi
  done < <(find "$APP_BUNDLE" \( -type f -o -type l \) -print0)

  while IFS= read -r library; do
    architectures="$(lipo -archs "$library")"
    [[ "$architectures" == *arm64* && "$architectures" == *x86_64* ]] || {
      echo "Bundled video dependency is not universal: $library ($architectures)" >&2
      exit 1
    }
    if otool -L "$library" | grep -E -q '/opt/homebrew|/usr/local'; then
      echo "Bundled video dependency contains a package-manager path: $library" >&2
      exit 1
    fi
    while IFS= read -r dependency; do
      case "$dependency" in
        @rpath/*|@loader_path/*|/usr/lib/*|/System/Library/*) ;;
        *)
          echo "Bundled video dependency contains a non-portable load path: $library -> $dependency" >&2
          exit 1
          ;;
      esac
    done < <(otool -L -arch arm64 "$library" | tail -n +2 | awk '{print $1}')
  done < <(find "$frameworks" -maxdepth 1 -name '*.dylib' -type f | sort)
}

verify_no_jit_entitlements() {
  local candidate
  local entitlements

  while IFS= read -r -d '' candidate; do
    if [[ "$candidate" != "$APP_BUNDLE" ]] \
      && [[ "$(LC_ALL=C file -Lb "$candidate")" != *Mach-O* ]]; then
      continue
    fi
    entitlements="$(codesign -d --entitlements :- "$candidate" 2>&1 || true)"
    if grep -E -q \
      'com\.apple\.security\.cs\.(allow-jit|allow-unsigned-executable-memory)' \
      <<< "$entitlements"; then
      echo "Full app contains prohibited executable-memory entitlements: $candidate" >&2
      exit 1
    fi
  done < <(
    find "$APP_BUNDLE" \( -type f -o -type l \) -print0
    printf '%s\0' "$APP_BUNDLE"
  )
}

verify_full_bundle

sign_bundle() {
  local item
  while IFS= read -r item; do
    chmod u+w "$item" 2>/dev/null || true
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$item" >/dev/null
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
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$item" >/dev/null
  done < <(
    find \
      "$APP_BUNDLE/Contents/MacOS" \
      "$APP_BUNDLE/Contents/Frameworks" \
      -type f ! -name '*.dylib' -perm -111 \
      2>/dev/null \
      | sort -u
  )
  codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP_BUNDLE" >/dev/null
  codesign --verify --deep --strict "$APP_BUNDLE"
  if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Signed full app with ad-hoc identity."
  else
    echo "Signed full app with release identity: $SIGNING_IDENTITY"
  fi
}

sign_bundle
verify_full_bundle
verify_no_jit_entitlements

rm -rf "$STAGING_DIR" "$DMG_PATH" "$CHECKSUM_PATH"
mkdir -p "$STAGING_DIR"
cp -R "$APP_BUNDLE" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

hdiutil create -volname "Niratan $VERSION" -srcfolder "$STAGING_DIR" -ov -format UDZO "$DMG_PATH"
for attempt in {1..5}; do
  if hdiutil verify "$DMG_PATH"; then
    break
  fi
  if [[ "$attempt" == "5" ]]; then
    echo "DMG verification failed after $attempt attempts." >&2
    exit 1
  fi
  sleep "$attempt"
done

SHA256="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
echo "$SHA256  $(basename "$DMG_PATH")" > "$CHECKSUM_PATH"
rm -rf "$STAGING_DIR"

echo "DMG_PATH=$DMG_PATH"
echo "CHECKSUM_PATH=$CHECKSUM_PATH"
echo "SHA256=$SHA256"
