import Foundation

let nativeBookshelf = try String(contentsOfFile: "NativeMac/NativeReuseViews.swift", encoding: .utf8)
let bookshelf = try String(contentsOfFile: "Features/Bookshelf/BookshelfView.swift", encoding: .utf8)
let shelf = try String(contentsOfFile: "Features/Bookshelf/ShelfView.swift", encoding: .utf8)
let bookCell = try String(contentsOfFile: "Features/Bookshelf/BookCell.swift", encoding: .utf8)
let matchSection = try String(contentsOfFile: "Features/Sasayaki/SasayakiMatchView.swift", encoding: .utf8)
let sheet = try String(contentsOfFile: "Features/Sasayaki/SasayakiSheet.swift", encoding: .utf8)
let player = try String(contentsOfFile: "Features/Sasayaki/SasayakiPlayer.swift", encoding: .utf8)
let reader = try String(contentsOfFile: "NativeMac/NativeReaderView.swift", encoding: .utf8)

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

for source in [nativeBookshelf, bookshelf, shelf, bookCell] {
    require(!source.contains("sasayakiBook"), "Bookshelf should not retain Sasayaki match sheet state")
    require(!source.contains("waveform.badge.magnifyingglass"), "Bookshelf context menu should not show Match")
    require(!source.contains("SasayakiMatchView("), "Bookshelf should not present a standalone match sheet")
}
require(
    matchSection.contains("struct SasayakiSubtitleMatchSection: View"),
    "Subtitle matching should be a reusable Resources section"
)
require(
    sheet.contains("SasayakiSubtitleMatchSection(") && sheet.contains("rootURL: player.rootURL"),
    "Reader Resources should host subtitle matching"
)
require(
    player.contains("func updateMatchData(_ matchData: SasayakiMatchData)"),
    "Player should accept a newly saved subtitle match"
)
require(
    player.contains(".applySasayakiCues(cues(for: getCurrentIndex())"),
    "A new match should immediately install cues in the current Reader chapter"
)
require(
    reader.contains("userConfig.enableSasayaki && model.sasayakiPlayer != nil"),
    "Reader should expose Sasayaki before a subtitle match exists"
)
require(
    matchSection.contains("FileNames.sasayakiMatch"),
    "Resources matching should preserve the existing sidecar filename"
)
require(
    matchSection.contains("@Binding var fileURL: URL?"),
    "Subtitle selection should be owned by the Sasayaki sheet"
)
require(
    !matchSection.contains(".fileImporter("),
    "Subtitle matching should not present a nested file importer"
)
require(
    sheet.contains("enum SasayakiFileImportKind"),
    "Sasayaki should centralize audio and subtitle file importing"
)
require(
    sheet.contains("Self.subtitleContentTypes") && sheet.contains(".plainText, .text"),
    "Subtitle importing should accept text fallback types"
)
require(
    sheet.contains("var isFileImporterPresented = false")
        && sheet.contains("isPresented: $isFileImporterPresented"),
    "File importer presentation should not clear the pending import kind before completion"
)
require(
    sheet.contains("pendingFileImportKind = .audio")
        && sheet.contains("pendingFileImportKind = .subtitle"),
    "Sasayaki should retain the selected import kind for both resources"
)
require(
    nativeBookshelf.contains("struct NativeSettingsActionButtonStyle: ButtonStyle")
        && matchSection.contains("buttonStyle(NativeSettingsActionButtonStyle())")
        && sheet.contains("buttonStyle(NativeSettingsActionButtonStyle())"),
    "Sasayaki resource actions should use the macOS 26 native glass button style"
)

print("Reader Sasayaki subtitle match contract passed")
