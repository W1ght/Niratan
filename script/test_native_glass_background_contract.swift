import Foundation

private func source(_ relativePath: String) throws -> String {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let url = root.appendingPathComponent(relativePath)
    return try String(contentsOf: url, encoding: .utf8)
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError("FAIL: \(message)")
    }
}

private func expectContains(_ source: String, _ needle: String, _ message: String) {
    expect(source.contains(needle), "\(message)\nMissing: \(needle)")
}

private func expectNotContains(_ source: String, _ needle: String, _ message: String) {
    expect(!source.contains(needle), "\(message)\nUnexpected: \(needle)")
}

let glass = try source("NativeMac/NativeGlassSurface.swift")
let root = try source("NativeMac/NativeMacRootView.swift")
let sidebar = try source("NativeMac/NativeMacSidebarView.swift")
let detail = try source("NativeMac/NativeMacDetailView.swift")
let reuse = try source("NativeMac/NativeReuseViews.swift")
let dictionarySearch = try source("Features/Dictionary/DictionarySearchView.swift")
let dictionarySettings = try source("Features/Settings/DictionaryView.swift")
let profileSettings = try source("Features/Settings/ProfilesView.swift")
let appearanceSettings = try source("Features/Settings/AppearanceView.swift")
let ankiSettings = try source("Features/Settings/AnkiView.swift")
let videoSettings = try source("Features/Settings/VideoSettingsView.swift")
let changelog = try source("docs/CHANGELOG.md")

expectContains(
    glass,
    "struct NativeGlassPageBackground: View",
    "Native glass page background should live in one shared native surface file"
)

expectContains(
    glass,
    "func nativeGlassCardSurface(cornerRadius: CGFloat = 18)",
    "Settings cards and other repeated surfaces should share one glass card modifier"
)

expectContains(
    glass,
    "func nativeGlassCapsuleSurface()",
    "Search fields and compact controls should share one glass capsule modifier"
)

expectContains(
    glass,
    "static func tint(for userConfig: UserConfig, colorScheme: ColorScheme) -> Color",
    "Glass tint should be calculated from the existing app theme and color scheme"
)

expectContains(
    root,
    "return .hidden",
    "Main window toolbar background should be hidden for app sections so glass extends into the titlebar"
)

expectContains(
    detail,
    "NativeGlassPageBackground()",
    "Main detail column should paint the shared glass background behind the selected section"
)

expect(
    sidebar.contains(".scrollContentBackground(.hidden)")
        && sidebar.contains("NativeGlassPageBackground()")
        && glass.contains("Color(nsColor: .windowBackgroundColor)")
        && !glass.contains("Material"),
    "Shared glass page, card and capsule surfaces must not stack SwiftUI Material beneath macOS 26 glass"
)

expect(
    reuse.contains("var settingsSidebar: some View")
        && reuse.contains(".listStyle(.sidebar)\n        .scrollContentBackground(.hidden)\n        .background(.clear)"),
    "Settings sidebar should reveal its shared theme-aware glass background"
)

expectContains(
    reuse,
    "NativeGlassPageBackground()",
    "Reusable native Bookshelf and Settings surfaces should use the shared glass background"
)

expectContains(
    reuse,
    ".nativeGlassCardSurface(cornerRadius: 18)",
    "Native Settings cards should use the shared glass card surface"
)

expectContains(
    reuse,
    "struct NativeSettingsActionButtonStyle: ButtonStyle",
    "Native Settings action buttons should use a shared button style"
)

expectContains(
    reuse,
    "GlassEffectContainer(spacing: 8)",
    "Native Settings action rows should group nearby macOS 26 glass buttons"
)

expectContains(
    reuse,
    ".glassEffect(.regular.interactive(), in: Capsule())",
    "Native Settings action buttons should render as interactive macOS 26 glass capsules"
)

expectContains(
    reuse,
    "struct NativeGlassMenuPicker<SelectionValue: Hashable, Label: View>: View",
    "Native Settings dropdowns should use a shared glass menu picker"
)

expectContains(
    reuse,
    "struct NativeGlassMenuPickerSurface: ViewModifier",
    "Native Settings dropdowns should share one glass menu surface modifier"
)

expect(
    reuse.contains("struct NativeSettingsEditableMenuField<MenuContent: View>: View")
        && reuse.contains(".glassEffect(.regular.interactive(), in: Capsule())")
        && reuse.contains(".menuStyle(.borderlessButton)")
        && reuse.contains(".menuIndicator(.hidden)"),
    "Editable Settings menus should combine text and selection in one macOS 26 glass surface without default material chrome"
)

expectContains(
    reuse,
    "Image(systemName: \"chevron.up.chevron.down\")",
    "Native Settings dropdowns should keep a familiar menu affordance"
)

expectNotContains(
    profileSettings,
    "NativeGlassMenuPicker(",
    "Profiles should not retain per-language default dropdowns now that selection is global"
)

expectContains(
    appearanceSettings,
    "NativeGlassMenuPicker(",
    "Appearance font dropdown should use the macOS 26 glass menu picker"
)

expectContains(
    ankiSettings,
    "NativeGlassMenuPicker(",
    "Anki deck/model dropdowns should use the macOS 26 glass menu picker"
)

expectContains(
    ankiSettings,
    "NativeSettingsEditableMenuField(",
    "Anki field mappings should use one combined editable macOS 26 glass menu field"
)

expectContains(
    videoSettings,
    "NativeGlassMenuPicker(",
    "Video subtitle font dropdown should use the macOS 26 glass menu picker"
)

expectContains(
    dictionarySearch,
    "NativeGlassTopScrim()",
    "Dictionary search should use a theme-aware glass top scrim instead of an opaque window-background gradient"
)

expectContains(
    dictionarySearch,
    ".nativeGlassCapsuleSurface()",
    "Dictionary search bar should use the shared glass capsule surface"
)

expectNotContains(
    dictionarySearch,
    "private var platformBackgroundColor: Color",
    "Dictionary search should not keep a page-level window-background color helper"
)

expectNotContains(
    dictionarySearch,
    "LinearGradient(colors: [platformBackgroundColor, .clear]",
    "Dictionary search should not cover the page with an opaque window-background gradient"
)

expectContains(
    dictionarySettings,
    "NativeGlassPageBackground()",
    "Dictionary CSS editor should use the shared native glass page background"
)

expectContains(
    changelog,
    "主界面、书架、词典和设置",
    "Changelog should mention the user-visible glass background update"
)

print("Native glass background contract passed")
