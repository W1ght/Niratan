# Niratan Mac Upstream Sync Queue

Use this queue to decide what to evaluate from `upstream/develop`. Upstream code is a behavior reference; Mac implementation must be adapted deliberately.

## Intake Checklist

Before applying upstream changes:

- Fetch and inspect upstream commits.
- Identify whether the diff touches Reader, WebView JS/CSS, Popup, Dictionary rendering, Settings, Sasayaki, Sync, Anki, or persistence.
- Compare user-visible behavior against current Mac behavior.
- Decide whether to port, adapt, defer, or reject the change.
- Record durable follow-up here only if it remains relevant after the task.

## High-Priority Watch Areas

### Reader / WebView

- Pagination, vertical writing, image sizing, safe-area, and focus-mode changes.
- JavaScript bridge changes in `reader.js` and `scrollreader.js`.
- Toolbar or root navigation changes that can affect native macOS window behavior.

### Dictionary / Popup

- Dictionary rendering templates and media handling.
- Popup layout CSS and nested popup behavior.
- Lookup shortcut and entry navigation behavior.

### Sync

- Google Drive token refresh, callback handling, conflict resolution, and progress timestamp logic.

### Audio

- Sasayaki cue handling and local dictionary audio changes.
- Any upstream fallback that could mix word audio with whole-book audio.

## Current Queue

- `c2e323b4` Sasayaki "Advance on Page Turn" plus `69ed0d19`: deferred from the paragraph mode port. Mac `SasayakiPlayer` diverges from upstream (chapter transition, pending cue restore), so page-bounded playback needs its own adaptation and real audiobook validation.
- `ede999c6`: evaluate pause-on-image playback separately from cross-chapter restore correctness. A Mac adaptation must share the existing Reader/Gallery image index and lyrics/statistics pipeline instead of copying the iOS settings and bridge state.
- `4940ab7e`: evaluate the sentence trailing-character change independently against Japanese and English context mining. The native selection script serves both Profile languages, so do not apply the upstream Japanese punctuation rule globally.
- Reader navigation architecture: compare future upstream navigation changes against the Mac-stable requirement that Books, Dictionary, and Settings remain predictable.
- Reader pagination: keep monitoring upstream vertical writing fixes, but test them in the native macOS WKWebView before adopting.
- Dictionary rendering: evaluate upstream dictionary media and popup rendering changes together, not independently.

## Adapted

- `c2e323b4` (`feat: paragraph (vn) mode`), `d310ea20` and `0288a79b`: adapted paragraph mode and text animation to the native paginated Reader. Pages are measured along Mac's top-to-bottom vertical pagination, paragraph mode forces single-column pages instead of two-column spreads, and settings are stored as optional Reader Profile fields. The Sasayaki page-advance part remains queued.
- `15d4a6e` (`feat: toggle furigana`), `23e0764`, `a4e16df`, `253a589` (`feat: add dimmed hide furigana option`) and `f4a7db0`: adapted to the native Reader injection as a Profile-owned four-mode setting that migrates the old Boolean and keeps writing it for older builds. Tap-to-reveal is click-only so Shift-hover lookup never reveals readings. `00f95c4` (furigana in highlights) remains unported.
- `d9f1b72` (`feat: google drive sync option`) with `c69f203`, `1cfbf71`, `ca7e053`, `241c92b`, `45ac6e9`, `1c5d525`, `77eaee3`, `4777715` and `62e5889`: adapted as the `gdrive` provider with Hoshi's existing Drive root, document format, per-session statistics and generation/deletion rules; see the Google Drive Sync section of `ARCHITECTURE_REFACTORING.md` for same-project OAuth configuration and the EPUB coordinate adapter. Format 1's Swift/JS coordinate rules remained stable from the first library-sync commit through `fb707c7a`; a TestFlight deployment still requires actual account/device verification. The Mac polls while active and applies newer synced bookmarks to an open Reader. `def6cec` is also adapted to upload book files from disk without assembling the complete media request in memory.
- `969b978` (search text size), `119fb5b`/`2c86ed6`/`9eff7dd` (dictionary categories and monolingual/bilingual handlebars, keeping Niratan's existing fallback handlebars), `baccc84` (audio source choice, as a right-click menu), `0a91398` (dictionary CSS scope) and `222a72b` (import errors): adapted to the native settings and popup.
- `165992a` (frequency sort order): adapted in Swift on top of the pinned hoshidicts fork, which has no `LookupOptions`; Auto keeps the fork's ranking and Ascending/Descending re-rank equally matched results by the chosen dictionary. Upstream's Disabled option needs fork support.

- `c098b865` (`feat: recursive lookups`) and `79fef08a` (`fix: correct recursive selection coordinates on zoomed popups for ios <26.4, pass scanLength instead of hardcoding`): adapted to the native macOS Dictionary search page with a dedicated original-query scan line. Clicking a character uses the configured scan length and highlights only the backend-matched term, while the upstream `lookupRedirect`/renderer replacement pattern redraws the existing results below instead of creating a child Popup. Entry headwords remain outside lookup; definition lookup, links, disclosure summaries, controls, and parent/child dismissal retain their existing Mac behavior.
- `f403c99b` (`feat: statistics reset time`) and `b4e6edd8` (`chore: replace stats reset time dropdown with datepicker`): adapted as one minute-level global Reset Time preference with a backward-compatible hour-to-minute migration. Native Reader writes and cross-day rollover plus the Bookshelf Statistics dashboard share one reporting-day boundary, including local-calendar and daylight-saving behavior.
- `cfc1e509` (`fix: build query off main thread`): adapted with a generation-tagged native query bundle. Dictionary construction leaves the main actor, stale builds cannot replace the requested Profile, unchanged configurations skip rebuilding, and lookups return no obsolete Profile data while a replacement is pending.
- `61a8c9db` (`fix: resolve relative paths manually`): adapted with EPUB-root-bounded component normalization for TTU image paths, including `.`/`..` handling and query/fragment removal, without resolving paths against the Mac host filesystem.
- `f54b55f4` (`fix: rank term and reading match first in local audio`), `8d1442e8` (`fix: add danger/success accent colors from yomitan to css`) and `5764c5c6` (`fix: use bindings instead of using indices for audio sources`): adapted to the native shared lookup/settings surfaces. Local audio ranks exact expression+reading pairs first, structured dictionary content receives light/dark semantic colors, and reordered sources mutate through stable bindings/IDs.
- The safe startup portion of `3f174c3a` (`fix: attempt to reduce startup pressure`): adapted without copying the iOS launch flow. Native local-media listener creation now logs and performs bounded retries instead of trapping, and shelf persistence safely handles an unavailable Application Support directory. Moving book migrations off the main actor remains intentionally unported because it needs a separate Mac data-safety launch gate.
- `078d59f4` (`fix: override publisher column-count in paginated mode`) and `bdf71a62` (`fix: remove webkit line-box property`): adapted in the native shared Reader injection. Nested publisher columns are neutralized only for paginated rendering so continuous layouts retain their authored structure; the WebKit line-box override is removed from both modes while Mac's explicit two-column body layout remains authoritative.
- `b717c575` (`fix: reuse highlight object`): adapted with one reusable CSS Highlight per Reader document while preserving Niratan's DOM-span fallback for WebKit environments without the CSS Highlights API. The related punctuation change remains queued for language-aware validation.
- `bcbef648` (`fix: calc chars for same-file entries in toc`) plus the statistics calculation from `2e1c958f`: adapted through a shared native chapter index. New imports persist fragment offsets using the Reader's normalized character rules; legacy `bookinfo.json` files receive a cancellable utility-priority backfill that reloads the latest sidecar and only merges missing offsets. Chapter highlighting and time-to-finish now use true TOC ranges, including multiple chapters in one XHTML file.
- `be88af18` (`fix: restore to actual cue progress instead of 0 when seeking across chapters`) and `e1d4b3b7` (`fix: load failed images`): adapted together for the native Reader. Cross-chapter Sasayaki navigation resolves the pending cue through the Mac bookmark/statistics boundary, flushes only the old reading position, persists the destination without counting the jump distance, and treats already-failed images as completed restore work instead of leaving cue setup pending.
- `76177841` (`fix: keep cross-node Sasayaki punctuation highlighted`), `e9690569` (`fix: prevent scrolling to cue in chapter when audio is paused`) and `83eb3193` (`fix: scroll to active cue in when unpausing in same chapter`): adapted to the shared paginated/continuous JavaScript and the native playback lifecycle.
- `6655ffdd` (`fix: filter numerically encoded chars`): adapted without deleting represented text. Niratan decodes decimal and hexadecimal HTML character references before Reader, Sasayaki and Gallery character filtering so persisted offsets continue to match rendered text.
- `98b65340` (`fix: strip whitespaces in ruby nodes`) and `3bff3908` (`fix: prevent scanning across expression tags`): adapted to the native Reader injection and shared selection boundary so ruby mutations use a stable node snapshot and lookup does not cross expression blocks.
- `54fab150` (`fix: pause stats when any sheet or fullscreenimageviewer is open`): adapted to the native Reader focus/coverage model. The live Statistics sheet remains an approved counting surface; other Reader sheets and the full-screen image overlay pause tracking.
- `fd124d4366009c4e2ee5d969f7f9b8907a0d4121` (`feat: image gallery`): adapted as a native macOS Reader menu and resizable image-grid sheet. Image paths are cached in backward-compatible `bookinfo.json` metadata, constrained to real JPG/PNG resources inside the extracted EPUB, and opened through the existing native Reader full-screen image viewer; the iOS sheet layout was not copied.
- `8ffca617204c357e69573741c70c8d57a463bfd5` (`feat: autofill lapis, kiku, senren`): ported the upstream template mappings with native Mac safe-merge semantics. Missing current-model fields are filled during config load, AnkiConnect refresh, and model selection; existing non-empty mappings are not overwritten automatically. Native Settings offers one confirmed restore for the shared EPUB/Video mapping, with `{book-cover}` and `{sasayaki-audio}` resolved by mining context. Lapis `DefinitionPicture` remains cleared because the retired heuristic preset once misclassified it as glossary content.
- `2e1c958f` (`feat: chapter progress display`) and `95ce7f59` (`feat: page count option`): adapted as Profile-scoped Show Progress / Show Chapter Progress toggles with an Off/Characters/Pages count and the existing percentage and position options. Chapter progress uses the shared TOC chapter index. Pages are measured by a hidden WKWebView that reuses the native Reader injection for each spine item, cached per book in `reader_pages.json` for the exact layout and window size, and unavailable in continuous mode. The upstream "Always Show Progress" option was not copied.
- The session-statistics portion of `d9f1b728` (`feat: google drive sync option`): reading is recorded and synced as per-book sessions in `statistics_sessions.json` (upstream session ids and legacy-day conversion), while the TTU daily `statistics.json` is re-derived on every save so TTU sync, backups and older builds keep working; daily rows written elsewhere are merged back by modification time. A Mac Reader left open across the reset time starts a new session, and the Statistics book panel edits or deletes individual sessions per day. Former daily-adapter sync history receives a one-time conversion that keeps shared historical IDs and avoids repeating their totals per device.
- Android `v1.2.0`: adapted named Japanese/English Profiles and English lookup behavior to native macOS. Mac keeps a shared AnkiConnect transport and physical dictionary store, uses explicit Reader/Video Profile contexts, and pins the multilingual hoshidicts fork at `c60de40bf5f000a28bd6d309383761cd881b196b`; Android input-method switching was intentionally not copied.
- `42e7b81` (`feat: use uikit toolbar and navigationbar for reader`) and `5a85d4e` (`fix: fade edge effect and bottom progress on ios 26, prevent progress from wrapping`): adapted as native Reader overlays. The title/progress stack and bottom statistics adopt the upstream bar typography as plain text (no glass capsules), and top/bottom edge fades follow the bars, hiding in focus mode and while an image is open. The fades are drawn over the WKWebView only; unlike iOS, the Mac page is not inset for the bars, so pagination and text layout are unchanged and overlapping text is handled by the existing title/progress visibility toggles.

## Deferred By Default

- `67fc9e8`/`dd5e7a2` (kanji dictionaries, stroke-order font) and `3cd8294` (pitch accent nasal/devoiced marks): need hoshidicts fork changes; kanji work is tracked separately.
- `93ba3be` (larger default popup size): Mac popup defaults are sized for the desktop window and unchanged.

- `2702e31d` (`fix: disable mine buttons if first field unconfigured, handle disconnected ankiconnect`): do not port its Anki mining gate to Mac. Both the direct port and a native preflight adaptation regressed the established Popup/Dictionary workflow, so Niratan retains its previous AnkiConnect behavior.
- iOS-only share extension behavior.
- AnkiMobile callback changes that do not apply to Mac AnkiConnect.
- Touch gesture changes that reintroduce accidental macOS navigation conflicts.
