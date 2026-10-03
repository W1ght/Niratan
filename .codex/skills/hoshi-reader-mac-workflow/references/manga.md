# Manga

Load this reference only for the Manga library, native Manga Reader, local media, Mokuro, OCR, Suwayomi, or manga mining.

## Required Context

- Read the `Manga Learning` section of `docs/ARCHITECTURE_REFACTORING.md`.
- Read the Manga and external-source sections of `docs/READER_REGRESSION_TESTING.md` when behavior or validation changes.
- Inspect the current `MangaReadingSession` and `MangaPageContentProvider` boundaries before adding source-specific behavior.

## Invariants

- Local folders, CBZ/ZIP, EPUB, Mokuro data, and custom covers are read-only user media plus App-owned metadata. Library actions must not move, rename, rewrite, or delete source files.
- Local, Suwayomi, and Aidoku pages adapt to the same native Reader, page processing, lookup, nested Popup, progress, and `MiningContext.manga` pipeline. Do not create a second Reader, lookup renderer, or Anki client.
- Suwayomi remains an external service managed by the user. Keep its configuration and library semantics Profile-scoped and its secrets in Keychain.
- Aidoku source lists, installed `.aix` packages, settings, login, online library, progress, and cache are App-global. The reader captures only the Profile active when it opens for lookup, Popup, and Anki. Run Aidoku code only through the repository's bounded Wasm3 compatibility layer; require safe ZIP extraction, ABI/import validation, 64 MiB linear-memory maximum, timeout/cancellation, atomic update/rollback, and an Aidoku-specific Keychain service. Never link or copy official `AidokuRunner`, restore Shinsou, execute Java/Mihon APKs, add JIT/XPC/helper executables, or expose arbitrary native/file-system APIs.
- Prefer embedded Mokuro text. On-device OCR (manga CTC, manga-ocr, Apple Vision) runs through `MangaOCREngineRouter`; its ONNX models are downloaded only on request from pinned revisions with size and SHA-256 checks. Google Lens is an unofficial network OCR path that uploads a reduced page image; preserve disclosure and explicit user choice, and never let automatic recognition select it. Requests, prefetch, OCR, and remote bootstrap work must be cancellable and discard stale session results.
- Cache identity and invalidation must separate source, server, Profile, chapter, page, and source modification state as applicable. Bounds and retries remain finite.

## Verification

- Use the focused `script/test_manga_*`, Suwayomi contract, or `Libraries/AidokuRuntime` tests selected by the changed boundary, then build and open the exact App for runtime work.
- UI validation uses a disposable local source, Profile, Suwayomi library, and repository-owned `.aix` fixture. Never validate by installing a live third-party source into a user's established Aidoku catalog.
- If no safe fixture or external server is available, report that limitation. Never repurpose the user's catalog, progress, OCR cache, source files, credentials, or server library.
- If shared Popup, audio, shortcuts, Anki, Profile, or build packaging changes, also load the corresponding reference.
