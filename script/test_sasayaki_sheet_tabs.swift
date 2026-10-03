import Foundation

private func read(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

let goTo = try read("Features/Reader/Search/ReaderGoToView.swift")
let sheet = try read("Features/Sasayaki/SasayakiSheet.swift")
let player = try read("Features/Sasayaki/SasayakiPlayer.swift")
let model = try read("Models/Sasayaki.swift")
let metadata = try read("Features/Sasayaki/SasayakiAudiobookMetadata.swift")

require(
    goTo.contains("var selectedTab: ReaderGoToTab = .chapters"),
    "Reader Go To should default to Chapters"
)
require(
    sheet.contains("case resources\n    case chapters\n    case settings"),
    "Sasayaki should expose Resources, Chapters and Settings tabs"
)
require(
    sheet.contains("NativeReaderInspectorTabBar("),
    "Sasayaki should switch tabs with the shared side-panel tab bar"
)
require(
    sheet.contains("player.seekToAudiobookChapter(chapter)"),
    "Sasayaki chapter rows should seek through the player"
)
require(
    metadata.contains("asset.loadChapterMetadataGroups("),
    "Sasayaki should load embedded audiobook chapters asynchronously"
)
require(
    player.contains("generation == self.audiobookChapterLoadGeneration"),
    "Sasayaki should reject stale chapter-loading results"
)
require(
    metadata.contains("SasayakiMP4ChapterParser.parse(url: fallbackURL)"),
    "Sasayaki should fall back to the M4B chpl chapter table"
)
require(
    metadata.contains(".commonKeyArtwork"),
    "Sasayaki should load embedded audiobook artwork"
)
require(
    metadata.contains("SasayakiMP4MetadataParser.parse(url: fallbackURL)"),
    "Sasayaki should fall back to M4B ilst metadata"
)
require(
    sheet.contains("SasayakiSubtitleMatchSection(") && sheet.contains("rootURL: player.rootURL"),
    "Sasayaki Resources should contain subtitle matching"
)
require(
    sheet.contains("player.audiobookMetadata.artworkData"),
    "Sasayaki playback header should render embedded audiobook artwork"
)
require(
    model.contains("struct SasayakiAudiobookChapter: Identifiable, Hashable"),
    "Sasayaki should model chapter identity and timing"
)

let localizationData = try Data(contentsOf: URL(fileURLWithPath: "Localizable.xcstrings"))
let localizationRoot = try JSONSerialization.jsonObject(with: localizationData) as? [String: Any]
let strings = localizationRoot?["strings"] as? [String: Any]
for key in [
    "Resources",
    "Current Chapter",
    "Loading Chapters...",
    "Chapter %d",
    "Subtitle Match",
    "Could not match subtitles."
] {
    let entry = strings?[key] as? [String: Any]
    let localizations = entry?["localizations"] as? [String: Any]
    require(localizations?["zh-Hans"] != nil, "\(key) should have Simplified Chinese localization")
    require(localizations?["zh-Hant"] != nil, "\(key) should have Traditional Chinese localization")
}

print("Sasayaki sheet tabs contract passed")
