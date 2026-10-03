import Foundation
import JavaScriptCore

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func source(_ path: String) throws -> String {
    try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func catalogKeys(_ path: String) throws -> [String: Any] {
    let data = try Data(contentsOf: root.appendingPathComponent(path))
    let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    return catalog?["strings"] as? [String: Any] ?? [:]
}

func requireTranslated(_ key: String, in catalog: [String: Any], _ name: String) {
    let entry = catalog[key] as? [String: Any]
    let localizations = entry?["localizations"] as? [String: Any]
    let zh = (localizations?["zh-Hans"] as? [String: Any])?["stringUnit"] as? [String: Any]
    require(zh?["value"] as? String != nil, "\(name) should translate \(key) into zh-Hans")
}

let userConfig = try source("Core/UserConfig.swift")
let profile = try source("Models/Profile.swift")
let appearance = try source("Features/Settings/AppearanceView.swift")
let nativeReader = try source("NativeMac/NativeReaderView.swift")
let selection = try source("Features/Reader/ReaderWebView/selection.js")
let lookupEngine = try source("Core/LookupEngine.swift")
let dictionaryModel = try source("Models/Dictionary.swift")
let dictionaryManager = try source("Core/DictionaryManager.swift")
let dictionaryView = try source("Features/Settings/DictionaryView.swift")
let dictionarySearch = try source("Features/Dictionary/DictionarySearchView.swift")
let popupView = try source("Features/Popup/PopupView.swift")
let popupWebView = try source("Features/Popup/PopupWebView.swift")
let popupScript = try source("Features/Popup/popup.js")
let anki = try source("Models/Anki.swift")
let ankiManager = try source("Core/AnkiManager.swift")
let localizable = try catalogKeys("Localizable.xcstrings")
let dictionaries = try catalogKeys("Dictionaries.xcstrings")

// Furigana: the four upstream modes, Profile-owned, migrating the old Boolean.
for mode in ["case off = \"Off\"", "case dimmed = \"Dimmed\"", "case toggle = \"Toggle\"", "case hidden = \"Hidden\""] {
    require(userConfig.contains(mode), "FuriganaMode should keep upstream raw value \(mode)")
}
require(userConfig.contains("rawValue.flatMap(FuriganaMode.init(rawValue:)) ?? (legacyHidden ? .hidden : .off)"),
        "a missing furigana mode should fall back to the legacy hide-furigana Boolean")
require(userConfig.contains("forKey: \"furiganaMode\""), "furigana mode should use upstream's defaults key")
require(userConfig.contains("Self.defaults.set(readerFuriganaMode == .hidden, forKey: \"readerHideFurigana\")"),
        "older builds should keep reading the legacy Boolean")
require(profile.contains("var furiganaMode: String? = nil"), "Profiles written by older builds should still decode")
require(userConfig.contains("hideFurigana: readerFuriganaMode == .hidden,"), "Profile export should keep the legacy field")
require(appearance.contains("values: FuriganaMode.allCases"), "Appearance should offer every furigana mode")
require(nativeReader.contains("userConfig.readerFuriganaMode.rawValue,"), "changing the mode should reload the Reader")
require(nativeReader.contains("ruby.classList.add('furigana-hidden');"), "toggle mode should hide furigana per ruby")
require(nativeReader.contains("document.querySelectorAll('rt').forEach(rt => rt.remove());"), "hidden mode should remove furigana")
require(nativeReader.contains("ruby > rt, ruby > rp { opacity: 0.4 !important; }"), "dimmed mode should fade furigana")
require(nativeReader.contains("color: transparent !important;"), "toggle mode should keep rt boxes to avoid reflow")
require(selection.contains("closest('ruby.furigana-hidden')"), "clicking hidden furigana should reveal it")
require(selection.contains("group.forEach(el => el.classList.remove('furigana-hidden'));"),
        "revealing should include adjacent ruby elements")
for key in ["Furigana", "Show", "Dimmed", "Tap to Reveal", "Hidden"] {
    requireTranslated(key, in: localizable, "Localizable")
}

// Frequency sorting and search text size are Profile-owned dictionary settings.
require(lookupEngine.contains("enum LookupFrequencySortOrder"), "lookup should expose a frequency sort order")
require(lookupEngine.contains("return sortedByFrequencyDictionary(results)"), "lookup results should be re-ranked")
require(lookupEngine.contains("if a.length != b.length"), "match length should stay the primary ranking key")
for field in ["var frequencySortOrder: String? = nil", "var frequencySortDictionary: String? = nil", "var searchTextSize: Int? = nil"] {
    require(profile.contains(field), "DictionaryProfileSettings should decode older Profiles without \(field)")
}
require(dictionarySearch.contains("style=\"font-size: \\(userConfig.searchTextSize)px;"), "search text should use the configured size")
require(userConfig.contains("frequencyDictionaryRenamedNotification"), "renamed frequency dictionaries should stay selected")

// Dictionary categories: monolingual/bilingual handlebars and Exclude for {glossary}.
require(dictionaryModel.contains("case none, monolingual, bilingual, exclude"), "dictionary categories should match upstream")
require(dictionaryModel.contains("var category: DictionaryCategory? = nil"), "older dictionary configs should still decode")
require(dictionaryManager.contains("func setDictionaryCategory(id: UUID, category: DictionaryCategory)"), "categories should be editable")
require(dictionaryView.contains("DictionaryCategoryPicker(selection:"), "term dictionaries should expose a category picker")
require(popupScript.contains("if (window.excludedDictionaries?.includes(dictName)) {"), "Exclude should drop a dictionary from {glossary}")
for host in [popupView, dictionarySearch] {
    require(host.contains("window.excludedDictionaries = \\(excludedDictionaries);"), "every popup host should inject excluded dictionaries")
    require(host.contains("window.audioSourceNames = \\(audioSourceNames);"), "every popup host should inject audio source names")
}
for handlebar in ["{monolingual-definition}", "{bilingual-definition}", "{monolingual-definition-fallback}", "{bilingual-definition-fallback}"] {
    require(anki.contains(handlebar), "Anki should offer \(handlebar)")
}
require(ankiManager.contains("private func categoryGlossary("), "category handlebars should resolve by dictionary order")
require(popupScript.contains(":where(div)[data-dictionary=\"${dictName}\"]"), "dictionary styles should not leak into other dictionaries")

// Audio source chooser: right-click lists every source result.
require(popupScript.contains("slot.addEventListener('contextmenu'"), "the audio button should open a source menu on right-click")
require(popupScript.contains("async function playEntryAudio(entryIndex, sourceIndex = null)"), "a chosen source should play directly")
require(popupWebView.contains("name: \"audioSourceMenu\""), "the popup should register the audio menu handler")
require(popupWebView.contains("removeScriptMessageHandler(forName: \"audioSourceMenu\")"), "the audio menu handler should be removed")

for key in ["Frequency Sorting", "Frequency Dictionary", "Ascending", "Descending", "Search Text", "Text Size",
            "Monolingual", "Bilingual", "Exclude", "No Category"] {
    requireTranslated(key, in: dictionaries, "Dictionaries")
}
for key in ["No audio found", "Play Audio", "Add to Anki", "Average", "Two-Column Layout"] {
    requireTranslated(key, in: localizable, "Localizable")
}

// The injected scripts must parse; a syntax error silently disables the whole Reader setup.
for path in ["Features/Reader/ReaderWebView/selection.js", "Features/Popup/popup.js"] {
    let script = JSStringCreateWithCFString(try source(path) as CFString)
    defer { JSStringRelease(script) }
    let context = JSGlobalContextCreate(nil)
    defer { JSGlobalContextRelease(context) }
    var exception: JSValueRef?
    let valid = JSCheckScriptSyntax(context, script, nil, 1, &exception)
    var message = ""
    if let exception, let text = JSValueToStringCopy(context, exception, nil) {
        message = JSStringCopyCFString(nil, text) as String
        JSStringRelease(text)
    }
    require(valid, "\(path) should be valid JavaScript: \(message)")
}

print("PASS: furigana modes and dictionary settings")
