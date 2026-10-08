// test-sources: Features/Sync/GoogleDriveSync/GoogleDriveSyncCache.swift
import Foundation

@main
struct GoogleDriveSyncCacheTest {
    static func main() throws {
        let legacy = Data(#"{"cursor":"old-cursor","root":"niratan-root","stateFolder":"old-state","bookFolder":"old-books","bookVersions":{"book":{"file":"hash"}},"bookFolders":{"book/1":"old-generation"}}"#.utf8)
        var cache = try JSONDecoder().decode(GoogleDriveSyncCache.self, from: legacy)
        require(cache.selectSharedLibrary(), "legacy cache must select the shared library")
        require(cache.libraryName == "Hoshi Reader", "shared library uses the upstream name")
        require(cache.root.isEmpty && cache.stateFolder.isEmpty && cache.bookFolder.isEmpty, "old folder IDs cannot leak into the shared library")
        require(cache.cursor == nil && cache.bookVersions.isEmpty && cache.bookFolders == nil, "old versions and change cursor must be invalidated")

        cache.root = "hoshi-root"
        cache.cursor = "hoshi-cursor"
        cache.bookVersions = ["book": ["file": "hash"]]
        var restored = try JSONDecoder().decode(GoogleDriveSyncCache.self, from: JSONEncoder().encode(cache))
        require(!restored.selectSharedLibrary(), "subsequent launches must keep shared cache state")
        require(restored == cache, "existing shared library references must survive")

        restored.requiresReattachment = true
        require(restored.selectSharedLibrary(force: true), "account change must reset even a shared-library cache")
        require(restored.root.isEmpty && restored.requiresReattachment == nil, "reattachment resets publications only after local work succeeds")

        restored.libraryName = "another-library"
        require(restored.selectSharedLibrary() && restored.root.isEmpty, "foreign library cache must also be invalidated")
        print("Google Drive shared library cache tests passed")
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
