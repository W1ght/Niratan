#!/usr/bin/env swift

import Foundation

let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let syncManagerURL = repo.appendingPathComponent("Features/Sync/SyncManager.swift")

guard let source = try? String(contentsOf: syncManagerURL, encoding: .utf8) else {
    fputs("Failed to read SyncManager.swift\n", stderr)
    exit(1)
}

func assertContains(_ needle: String, _ message: String) {
    guard source.contains(needle) else {
        fputs("Missing expected sync contract: \(message)\n", stderr)
        exit(1)
    }
}

assertContains(
    "func shouldImportAudioBook(remoteFile: DriveFile?, bookFolder: URL) -> Bool",
    "Sasayaki audiobook sync must decide remote-only imports separately from bookmark progress."
)
assertContains(
    "func parseAudioBookTimestamp(from file: DriveFile) -> Date?",
    "Sasayaki audiobook sync must parse the audioBook_ file timestamp."
)
assertContains(
    ".modificationDate",
    "Sasayaki audiobook sync must compare the remote timestamp with the local playback sidecar modification date."
)
assertContains(
    "if importOnly,\n           syncDirection == .synced,\n           syncAudioBook,\n           shouldImportAudioBook(remoteFile: syncFiles.audioBook, bookFolder: url),",
    "Opening the reader must import a newer remote audiobook position even when bookmark progress is already synced."
)

guard let audiobookImportRange = source.range(of: "shouldImportAudioBook(remoteFile: syncFiles.audioBook, bookFolder: url)") else {
    fputs("Missing audiobook-only import branch\n", stderr)
    exit(1)
}
guard let syncedReturnRange = source.range(of: "if syncDirection == .synced {\n            return .synced") else {
    fputs("Missing synced return branch\n", stderr)
    exit(1)
}
guard audiobookImportRange.lowerBound < syncedReturnRange.lowerBound else {
    fputs("Audiobook-only import must run before the early synced return\n", stderr)
    exit(1)
}

print("Sasayaki sync contract passed")
