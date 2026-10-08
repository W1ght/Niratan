import Foundation

/// Folder IDs and change cursors belong to one cloud library. Older Niratan caches did not
/// record the name and must never be reused against the shared Hoshi Reader library.
nonisolated struct GoogleDriveSyncCache: Codable, Equatable {
    static let sharedLibraryName = "Hoshi Reader"

    var libraryName: String? = Self.sharedLibraryName
    /// Persist before changing accounts so local I/O failure cannot reuse old publications.
    var requiresReattachment: Bool?
    var cursor: String?
    var root = ""
    var stateFolder = ""
    var bookFolder = ""
    var bookVersions: [String: [String: String]] = [:]
    var bookFolders: [String: String]?

    @discardableResult
    mutating func selectSharedLibrary(force: Bool = false) -> Bool {
        guard force || libraryName != Self.sharedLibraryName else { return false }
        self = Self()
        return true
    }
}
