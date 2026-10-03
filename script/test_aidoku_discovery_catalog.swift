// test-sources: Models/Aidoku.swift
// test-modules: AidokuRuntime ZIPFoundation SwiftSoup Wasm3 wasm3-c wasm3-support AidokuRuntimeWatchdog
import AidokuRuntime
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
private enum AidokuDiscoveryCatalogTests {
    static func main() throws {
        let manga = AidokuManga(key: "manga-old", title: "星の漫画")
        let entry = AidokuLibraryEntry(
            sourceID: "source.example",
            sourceName: "Fixture Source",
            manga: manga,
            addedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20),
            discoveryWorkID: "mal:42"
        )
        let mapping = AidokuDiscoverySourceMapping(
            sourceID: "source.example",
            manga: manga,
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        var catalog = AidokuGlobalCatalog()
        catalog.library = [entry]
        catalog.progress = [AidokuChapterProgress(
            sourceID: "source.example",
            mangaKey: manga.key,
            chapterKey: "chapter-1",
            pageIndex: 3,
            pageCount: 20,
            completed: false,
            updatedAt: Date(timeIntervalSince1970: 40)
        )]
        catalog.discoverySourceMappings = ["mal:42": mapping]

        let encoded = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(AidokuGlobalCatalog.self, from: encoded)
        expect(decoded.discoverySourceMappings?["mal:42"] == mapping, "discovery mappings must round-trip")
        expect(decoded.library.first?.discoveryWorkID == "mal:42", "library entries must retain discovery identity")

        var legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacyObject.removeValue(forKey: "discoverySourceMappings")
        var legacyLibrary = legacyObject["library"] as! [[String: Any]]
        legacyLibrary[0].removeValue(forKey: "discoveryWorkID")
        legacyObject["library"] = legacyLibrary
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(AidokuGlobalCatalog.self, from: legacyData)
        expect(legacy.discoverySourceMappings == nil, "catalogs written before discovery mappings must decode as empty")
        expect(legacy.library.first?.discoveryWorkID == nil, "legacy library entries must decode without a discovery identity")

        var unavailable = decoded
        unavailable.installedSources = []
        expect(unavailable.discoverySourceMappings?["mal:42"] == mapping, "uninstalling a source must not make its mapping undecodable")
        expect(unavailable.progress.first?.mangaKey == "manga-old", "source replacement must not rewrite prior progress")

        print("Aidoku discovery catalog tests passed")
    }
}
