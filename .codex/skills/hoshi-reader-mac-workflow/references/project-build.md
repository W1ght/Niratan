# Project, Build, Packaging, and Runtime Identity

Load this reference only for Xcode project changes, dependencies, build scripts, target membership, packaging, signing, or launch verification.

## Build Boundary

- `Niratan` is the only target and scheme. Debug and Release both contain Reader, Video, and Manga; do not restore Light/Video variants or `HOSHI_VIDEO`.
- The full build links universal libmpv, packages the pinned YouTubeKit resources, and links the local `AidokuRuntime` package with vendored Wasm3 plus pinned SwiftSoup. YouTubeKit's approved local system-JavaScriptCore path and the bounded Aidoku compatibility layer are distinct from prohibited Shinsou, official AidokuRunner, Java/APK, JIT, XPC, and helper runtimes.
- `script/package_mac.sh` is the packaging source of truth. Keep packaged libraries relocatable and free of Homebrew paths or unapproved helper executables.
- For new files under an Xcode synchronized root group, check membership exceptions instead of assuming project inclusion.

## Build and Launch

- Use `./script/build_and_run.sh --verify` for the default full-feature build. Signing/profile failures are not code regressions unless the task concerns signing or distribution.
- Verification must match both `CFBundleIdentifier == moe.shishamo.hoshi` and the running executable inside the exact built `.app`.
- Never select or validate a build by process name, window title, bundle id alone, or an unqualified `/Applications/Niratan.app`.
- Parallel sessions use distinct `--instance` or DerivedData paths, but still share bundle-domain preferences and user data.
- `--data-root <dir>` (Debug builds) keeps defaults, Application Support, caches and Keychain items under `<dir>`; use it whenever verification would write user data. `--appearance dark|light` stands in for the system appearance.

## Verification

- Run the focused build/package contract affected by the change, such as the full-build, native-release, Video dependency, or Manga external-runtime boundary.
- After changing runnable project or packaging inputs, build and launch the exact product unless the task is pure CI/release orchestration covered by `release.md`.
- Inspect signing, embedded resources, dylib load paths, and bundle contents only to the depth required by the changed boundary.
