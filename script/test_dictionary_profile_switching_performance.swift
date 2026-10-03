import Foundation

private func read(_ path: String) -> String {
    guard let value = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("FAIL: unable to read \(path)\n", stderr)
        exit(1)
    }
    return value
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func methodBody(in source: String, signature: String) -> Substring? {
    guard let signatureRange = source.range(of: signature),
          let openingBrace = source[signatureRange.lowerBound...].firstIndex(of: "{") else {
        return nil
    }

    var depth = 0
    var index = openingBrace
    while index < source.endIndex {
        switch source[index] {
        case "{":
            depth += 1
        case "}":
            depth -= 1
            if depth == 0 {
                return source[source.index(after: openingBrace)..<index]
            }
        default:
            break
        }
        index = source.index(after: index)
    }
    return nil
}

private func productionSwiftSources() -> [(path: String, source: String)] {
    let fileManager = FileManager.default
    let roots = ["Core", "Features", "Libraries", "Models", "NativeMac", "Util", "Vendor"]
    return roots.flatMap { directory -> [(path: String, source: String)] in
        guard let enumerator = fileManager.enumerator(atPath: directory) else { return [] }
        return enumerator.compactMap { entry -> (path: String, source: String)? in
            guard let relativePath = entry as? String,
                  relativePath.hasSuffix(".swift") else { return nil }
            let path = "\(directory)/\(relativePath)"
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            return (path, source)
        }
    }
}

private func compactCode(_ source: String) -> String {
    source.filter { !$0.isWhitespace }
}

let root = read("NativeMac/NativeMacRootView.swift")
let dictionaryManager = read("Core/DictionaryManager.swift")
let lookupEngine = read("Core/LookupEngine.swift")
let dictionarySearch = read("Features/Dictionary/DictionarySearchView.swift")
let backup = read("Features/Settings/BackupView.swift")
let profilesView = read("Features/Settings/ProfilesView.swift")
let readerPresenter = read("NativeMac/ReaderWindowPresenter.swift")
let videoPresenter = read("NativeMac/VideoWindowPresenter.swift")
let productionSources = productionSwiftSources()

require(
    !root.contains(".id(selectedSection)")
        && !root.contains("ProfileActivationCoordinator")
        && !root.contains("profileRepository")
        && !readerPresenter.contains("ProfileActivationCoordinator")
        && !videoPresenter.contains("ProfileActivationCoordinator")
        && profilesView.contains("ProfileActivationCoordinator.activateGlobal("),
    "ordinary navigation and Reader/Video window activity must keep one stable host and leave global Profile activation to ProfilesView"
)
require(
    productionSources
        .filter { compactCode($0.source).contains(".setGlobalActiveProfile(") }
        .allSatisfy { $0.path == "Features/Settings/ProfilesView.swift" }
        && productionSources
            .filter { compactCode($0.source).contains("ProfileActivationCoordinator.activateGlobal(") }
            .allSatisfy { $0.path == "Features/Settings/ProfilesView.swift" }
        && compactCode(profilesView).contains(".setGlobalActiveProfile(")
        && compactCode(profilesView).contains("ProfileActivationCoordinator.activateGlobal("),
    "ProfilesView must be the only production caller that selects and activates the global Profile"
)
require(
    productionSources.allSatisfy {
        let source = compactCode($0.source)
        return !source.contains("resolve(.book")
            && !source.contains("resolve(.video")
            && !source.contains("book.profileId")
    },
    "Reader, Video and bookshelf runtime code must not consume legacy per-book or per-video Profile selections"
)

guard let activationBody = methodBody(
    in: dictionaryManager,
    signature: "func activateProfile(_ profileID: String)"
) else {
    fputs("FAIL: unable to isolate DictionaryManager.activateProfile\n", stderr)
    exit(1)
}
require(
    activationBody.contains("guard activeProfileID != profileID else { return }")
        && activationBody.contains("applyActiveProfileDictionaryConfiguration()")
        && !activationBody.contains("loadDictionaries()")
        && !activationBody.contains("scanPhysicalDictionaryCatalog()"),
    "Profile activation must skip identical Profiles and merge configuration from the shared physical catalog"
)

guard let loadBody = methodBody(
    in: dictionaryManager,
    signature: "func loadDictionaries()"
) else {
    fputs("FAIL: unable to isolate DictionaryManager.loadDictionaries\n", stderr)
    exit(1)
}
guard let applyBody = methodBody(
    in: dictionaryManager,
    signature: "private func applyActiveProfileDictionaryConfiguration()"
) else {
    fputs("FAIL: unable to isolate DictionaryManager.applyActiveProfileDictionaryConfiguration\n", stderr)
    exit(1)
}
require(
    dictionaryManager.contains("struct PhysicalDictionaryCatalog")
        && dictionaryManager.contains("var physicalDictionaryCatalog: PhysicalDictionaryCatalog?")
        && loadBody.contains("physicalDictionaryCatalog = scanPhysicalDictionaryCatalog()"),
    "explicit dictionary refreshes must rebuild the shared physical catalog"
)
require(
    applyBody.contains("guard let physicalDictionaryCatalog")
        && !applyBody.contains("getDictionariesFromStorage")
        && !applyBody.contains("scanPhysicalDictionaryCatalog"),
    "Profile switches must reuse the cached physical catalog and only merge enabled/order configuration"
)

guard let buildBody = methodBody(in: lookupEngine, signature: "func buildQuery(") else {
    fputs("FAIL: unable to isolate LookupEngine.buildQuery\n", stderr)
    exit(1)
}
require(
    lookupEngine.contains("var activeConfiguration")
        && lookupEngine.contains("var requestedConfiguration")
        && lookupEngine.contains("nonisolated final class QueryBundle: @unchecked Sendable")
        && lookupEngine.contains("private(set) var isReadyForLookup = false")
        && buildBody.contains("Task.detached(priority: .userInitiated)")
        && buildBody.contains("configuration == self.requestedConfiguration")
        && lookupEngine.contains("isReadyForLookup, let bundle, activeConfiguration == requestedConfiguration")
        && dictionarySearch.contains("LookupEngine.shared.isReadyForLookup")
        && buildBody.contains("contentGeneration: contentGeneration"),
    "native query construction must run off the main actor, discard stale generations, hide obsolete Profile results, and retry pending Dictionary searches"
)
require(
    dictionaryManager.contains("LookupEngine.shared.buildQuery(")
        && dictionaryManager.contains("contentGeneration: dictionaryCatalogGeneration"),
    "DictionaryManager must include the physical catalog generation in the effective query signature"
)

for signature in [
    "func importRecommendedDictionaries(",
    "func importDictionary(from urls:",
    "func updateDictionaries(",
    "func deleteDictionary("
] {
    guard let body = methodBody(in: dictionaryManager, signature: signature) else {
        fputs("FAIL: unable to isolate DictionaryManager.\(signature)\n", stderr)
        exit(1)
    }
    require(
        body.contains("loadDictionaries()")
            && body.contains("refreshLookupQueryIfNeeded()"),
        "\(signature) must refresh both the physical catalog and effective native query after writes"
    )
}

require(
    dictionaryManager.contains("func reloadActiveProfileDictionaryState()")
        && dictionaryManager.contains("loadDictionaries()\n        loadCollapsedDictionaries()\n        refreshLookupQueryIfNeeded()")
        && backup.contains("DictionaryManager.shared.reloadActiveProfileDictionaryState()"),
    "dictionary restore must refresh the shared physical catalog, Profile configuration, collapsed state, and native query"
)
require(
    dictionaryManager.contains("func loadCollapsedDictionaries() {\n        collapsedDictionaries = []"),
    "a Profile without collapsed dictionary state must not inherit the previous Profile's state"
)

print("Dictionary Profile switching performance contracts passed")
