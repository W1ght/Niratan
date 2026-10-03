import AppKit
import Foundation
import Observation

/// How pages flow through the reader. Mirrors Fushi's manga reading modes:
/// horizontal spreads, one page per screen turning vertically, and a
/// continuous long strip with or without gaps.
nonisolated enum MangaReaderMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case paged
    case verticalPaged
    case continuous

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .paged: "Paged"
        case .verticalPaged: "Vertical Pages"
        case .continuous: "Long Strip"
        }
    }

    var systemImage: String {
        switch self {
        case .paged: "book.pages"
        case .verticalPaged: "rectangle.portrait.arrowtriangle.2.outward"
        case .continuous: "rectangle.stack"
        }
    }

    var isPaged: Bool { self != .continuous }
}

/// Single/double page choice used by the horizontal paged mode.
nonisolated enum MangaSpreadMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case single
    case double

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .automatic: "Automatic"
        case .single: "Single Page"
        case .double: "Double Page"
        }
    }

    var systemImage: String {
        switch self {
        case .automatic: "rectangle.split.2x1"
        case .single: "rectangle.portrait"
        case .double: "book.pages"
        }
    }
}

nonisolated enum MangaPageScaleType: String, Codable, CaseIterable, Identifiable, Sendable {
    case fitScreen
    case fitWidth
    case fitHeight
    case original
    case stretch

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .fitScreen: "Fit Screen"
        case .fitWidth: "Fit Width"
        case .fitHeight: "Fit Height"
        case .original: "Original Size"
        case .stretch: "Stretch"
        }
    }
}

nonisolated enum MangaPageAnimation: String, Codable, CaseIterable, Identifiable, Sendable {
    case slide
    case fade
    case none

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .slide: "Slide"
        case .fade: "Fade"
        case .none: "None"
        }
    }
}

/// Click-zone layouts. Geometry follows Fushi's `manga_view_prefs.dart`
/// (`left_right`, `l_shaped`, `kindle`, `edge`, `right_left`).
nonisolated enum MangaTapZoneLayout: String, Codable, CaseIterable, Identifiable, Sendable {
    case leftRight
    case lShaped
    case kindle
    case edge
    case rightLeft
    case disabled

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .leftRight: "Left and Right"
        case .lShaped: "L-Shaped"
        case .kindle: "Kindle-ish"
        case .edge: "Edge"
        case .rightLeft: "Right and Left"
        case .disabled: "Disabled"
        }
    }
}

nonisolated enum MangaTapZoneAction: Equatable, Sendable {
    case previous
    case next
    case menu
}

nonisolated enum MangaReaderBackground: String, Codable, CaseIterable, Identifiable, Sendable {
    case black
    case white
    case gray
    case system

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .black: "Black"
        case .white: "White"
        case .gray: "Gray"
        case .system: "Follow Appearance"
        }
    }
}

nonisolated enum MangaOCRTrigger: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case manual

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .automatic: "When Opening"
        case .manual: "Manually"
        }
    }
}

/// OCR engine preference. `automatic` prefers the downloaded local models
/// (manga CTC, then manga-ocr) and falls back to Apple Vision; it never
/// selects Google Lens, which uploads pages and therefore always requires an
/// explicit choice plus disclosure.
nonisolated enum MangaOCREngineChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case mangaCTC
    case mangaOCR
    case appleVision
    case googleLens

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .automatic: "Automatic"
        case .mangaCTC: "Manga CTC (Fast)"
        case .mangaOCR: "manga-ocr"
        case .appleVision: "Apple Vision"
        case .googleLens: "Google Lens"
        }
    }

    var uploadsPages: Bool {
        self == .googleLens
    }
}

/// Every Fushi manga reader option that applies to the Mac reader. Values are
/// stored once globally and may be overridden per title; any field missing
/// from stored JSON falls back to the default below, so new options never
/// invalidate saved settings.
nonisolated struct MangaReaderSettings: Codable, Equatable, Sendable {
    static let minimumZoomPercentage = 50
    static let maximumZoomPercentage = 400
    static let webtoonAspectThreshold = 2.0

    var mode: MangaReaderMode = .paged
    var autoDetectsMode = false
    var spreadMode: MangaSpreadMode = .automatic
    var direction: MangaReadingDirection = .rightToLeft
    var showsCoverAlone = true
    var showsWidePagesAlone = true
    var scaleType: MangaPageScaleType = .fitScreen
    var zoomPercentage = 100
    var disablesZoomOut = false
    var zoomSensitivity = 100
    var doubleClickZoom = true
    var animatesDoubleClickZoom = true
    var pageAnimation: MangaPageAnimation = .slide
    var flashesOnPageChange = false
    var tapZoneLayout: MangaTapZoneLayout = .leftRight
    var invertsTapZonesHorizontally = false
    var invertsTapZonesVertically = false
    var showsTapZonesOnOpen = false
    var showsPageGaps = true
    var sidePaddingPercent = 0
    var background: MangaReaderBackground = .black
    var usesAutomaticBackground = false
    var invertsColors = false
    var grayscale = false
    var brightness = 0
    var contrast = 100
    var saturation = 100
    var usesCustomColorFilter = false
    var customColorFilterHex = "#F4ECD8"
    var customColorFilterOpacity = 20
    var einkMode = false
    var cropsBorders = false
    var splitsWidePages = false
    var rotatesWidePages = false
    var showsPageNumber = true
    var showsReadingModeHint = true
    var hidesInterfaceOnScroll = true
    var ocrTrigger: MangaOCRTrigger = .automatic
    var ocrEngine: MangaOCREngineChoice = .automatic
    var showsOCRBoxes = false
    var looksUpOnHover = false
    var panelNavigation = false
    var autoScroll = false
    var autoScrollSpeed = 40
    var keepsScreenOn = true

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = MangaReaderSettings()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        mode = value(.mode, defaults.mode)
        autoDetectsMode = value(.autoDetectsMode, defaults.autoDetectsMode)
        spreadMode = value(.spreadMode, defaults.spreadMode)
        direction = value(.direction, defaults.direction)
        showsCoverAlone = value(.showsCoverAlone, defaults.showsCoverAlone)
        showsWidePagesAlone = value(.showsWidePagesAlone, defaults.showsWidePagesAlone)
        scaleType = value(.scaleType, defaults.scaleType)
        zoomPercentage = value(.zoomPercentage, defaults.zoomPercentage)
        disablesZoomOut = value(.disablesZoomOut, defaults.disablesZoomOut)
        zoomSensitivity = value(.zoomSensitivity, defaults.zoomSensitivity)
        doubleClickZoom = value(.doubleClickZoom, defaults.doubleClickZoom)
        animatesDoubleClickZoom = value(.animatesDoubleClickZoom, defaults.animatesDoubleClickZoom)
        pageAnimation = value(.pageAnimation, defaults.pageAnimation)
        flashesOnPageChange = value(.flashesOnPageChange, defaults.flashesOnPageChange)
        tapZoneLayout = value(.tapZoneLayout, defaults.tapZoneLayout)
        invertsTapZonesHorizontally = value(.invertsTapZonesHorizontally, defaults.invertsTapZonesHorizontally)
        invertsTapZonesVertically = value(.invertsTapZonesVertically, defaults.invertsTapZonesVertically)
        showsTapZonesOnOpen = value(.showsTapZonesOnOpen, defaults.showsTapZonesOnOpen)
        showsPageGaps = value(.showsPageGaps, defaults.showsPageGaps)
        sidePaddingPercent = value(.sidePaddingPercent, defaults.sidePaddingPercent)
        background = value(.background, defaults.background)
        usesAutomaticBackground = value(.usesAutomaticBackground, defaults.usesAutomaticBackground)
        invertsColors = value(.invertsColors, defaults.invertsColors)
        grayscale = value(.grayscale, defaults.grayscale)
        brightness = value(.brightness, defaults.brightness)
        contrast = value(.contrast, defaults.contrast)
        saturation = value(.saturation, defaults.saturation)
        usesCustomColorFilter = value(.usesCustomColorFilter, defaults.usesCustomColorFilter)
        customColorFilterHex = value(.customColorFilterHex, defaults.customColorFilterHex)
        customColorFilterOpacity = value(.customColorFilterOpacity, defaults.customColorFilterOpacity)
        einkMode = value(.einkMode, defaults.einkMode)
        cropsBorders = value(.cropsBorders, defaults.cropsBorders)
        splitsWidePages = value(.splitsWidePages, defaults.splitsWidePages)
        rotatesWidePages = value(.rotatesWidePages, defaults.rotatesWidePages)
        showsPageNumber = value(.showsPageNumber, defaults.showsPageNumber)
        showsReadingModeHint = value(.showsReadingModeHint, defaults.showsReadingModeHint)
        hidesInterfaceOnScroll = value(.hidesInterfaceOnScroll, defaults.hidesInterfaceOnScroll)
        ocrTrigger = value(.ocrTrigger, defaults.ocrTrigger)
        ocrEngine = value(.ocrEngine, defaults.ocrEngine)
        showsOCRBoxes = value(.showsOCRBoxes, defaults.showsOCRBoxes)
        looksUpOnHover = value(.looksUpOnHover, defaults.looksUpOnHover)
        panelNavigation = value(.panelNavigation, defaults.panelNavigation)
        autoScroll = value(.autoScroll, defaults.autoScroll)
        autoScrollSpeed = value(.autoScrollSpeed, defaults.autoScrollSpeed)
        keepsScreenOn = value(.keepsScreenOn, defaults.keepsScreenOn)
        normalize()
    }

    /// Clamps numeric options to the ranges exposed by the settings panel.
    mutating func normalize() {
        zoomPercentage = Self.clampedZoomPercentage(zoomPercentage)
        zoomSensitivity = min(400, max(25, zoomSensitivity))
        sidePaddingPercent = min(24, max(0, sidePaddingPercent))
        brightness = min(100, max(-100, brightness))
        contrast = min(200, max(0, contrast))
        saturation = min(200, max(0, saturation))
        customColorFilterOpacity = min(100, max(0, customColorFilterOpacity))
        autoScrollSpeed = min(200, max(5, autoScrollSpeed))
        if Self.color(fromHex: customColorFilterHex) == nil {
            customColorFilterHex = MangaReaderSettings().customColorFilterHex
        }
    }

    static func clampedZoomPercentage(_ percentage: Int) -> Int {
        min(maximumZoomPercentage, max(minimumZoomPercentage, percentage))
    }

    var minimumEffectiveZoomPercentage: Int {
        disablesZoomOut ? 100 : Self.minimumZoomPercentage
    }

    var effectivePageAnimation: MangaPageAnimation {
        einkMode ? .none : pageAnimation
    }

    var effectiveGrayscale: Bool {
        grayscale || einkMode
    }

    var hasImageFilter: Bool {
        invertsColors || effectiveGrayscale || brightness != 0
            || contrast != 100 || saturation != 100
    }

    var customColorFilterColor: NSColor? {
        guard usesCustomColorFilter, customColorFilterOpacity > 0 else {
            return nil
        }
        return Self.color(fromHex: customColorFilterHex)?
            .withAlphaComponent(CGFloat(customColorFilterOpacity) / 100)
    }

    static func color(fromHex hex: String) -> NSColor? {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") {
            value.removeFirst()
        }
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else {
            return nil
        }
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    /// Resolves the page-background color. `pageLuminance` is the corner
    /// luminance of the current page and is only used for the automatic mode.
    func backgroundColor(pageLuminance: Double?) -> NSColor {
        if einkMode {
            return .white
        }
        if usesAutomaticBackground, let pageLuminance {
            return pageLuminance >= 0.5 ? .white : .black
        }
        switch background {
        case .black: return .black
        case .white: return .white
        case .gray: return NSColor(srgbRed: 0x2B / 255, green: 0x2B / 255, blue: 0x2B / 255, alpha: 1)
        case .system: return .windowBackgroundColor
        }
    }

    /// Resolves the click zone for a point given in viewport coordinates with a
    /// top-left origin, normalized to 0...1.
    func tapZoneAction(at point: CGPoint) -> MangaTapZoneAction? {
        var x = min(1, max(0, point.x))
        var y = min(1, max(0, point.y))
        if invertsTapZonesHorizontally {
            x = 1 - x
        }
        if invertsTapZonesVertically {
            y = 1 - y
        }
        // Side zones mean "toward the page shown on that side", so they follow
        // the reading direction, like the arrow keys.
        let leftAction: MangaTapZoneAction = direction == .rightToLeft ? .next : .previous
        let rightAction: MangaTapZoneAction = direction == .rightToLeft ? .previous : .next
        switch tapZoneLayout {
        case .disabled:
            return nil
        case .leftRight:
            if x < 1.0 / 3 { return leftAction }
            if x > 2.0 / 3 { return rightAction }
            return .menu
        case .rightLeft:
            if x < 1.0 / 3 { return rightAction }
            if x > 2.0 / 3 { return leftAction }
            return .menu
        case .lShaped:
            if y < 1.0 / 3 {
                return x < 2.0 / 3 ? .previous : .next
            }
            if y > 2.0 / 3 {
                return x < 1.0 / 3 ? .previous : .next
            }
            if x < 1.0 / 3 { return .previous }
            if x > 2.0 / 3 { return .next }
            return .menu
        case .kindle:
            if y < 1.0 / 3 { return .menu }
            return x < 1.0 / 3 ? .previous : .next
        case .edge:
            if x < 1.0 / 3 || x > 2.0 / 3 || y > 2.0 / 3 {
                return .next
            }
            return .menu
        }
    }
}

/// Global manga reader settings plus sparse per-title overrides. Global values
/// live in UserDefaults; overrides are App-owned metadata in Application
/// Support and never touch imported manga files.
@Observable
@MainActor
final class MangaReaderSettingsStore {
    static let shared = MangaReaderSettingsStore()

    nonisolated static let globalKey = "mangaReaderSettings"
    nonisolated static let overridesFileName = "manga_reader_overrides.json"

    private(set) var global: MangaReaderSettings
    private(set) var overrides: [String: [String: Any]] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let overridesURL: URL
    @ObservationIgnored private var writeTask: Task<Void, Never>?

    init(
        defaults: UserDefaults = .standard,
        overridesURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.defaults = defaults
        let supportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.overridesURL = overridesURL
            ?? supportDirectory.appendingPathComponent(Self.overridesFileName)
        global = Self.loadGlobal(from: defaults)
        overrides = Self.loadOverrides(from: self.overridesURL)
    }

    func effectiveSettings(for documentID: String) -> MangaReaderSettings {
        guard let titleOverrides = overrides[documentID],
              !titleOverrides.isEmpty,
              var merged = Self.dictionary(from: global) else {
            return global
        }
        merged.merge(titleOverrides) { _, override in override }
        return Self.settings(from: merged) ?? global
    }

    func overriddenKeys(for documentID: String) -> Set<String> {
        Set(overrides[documentID]?.keys.map { $0 } ?? [])
    }

    func updateGlobal(_ settings: MangaReaderSettings) {
        var settings = settings
        settings.normalize()
        guard settings != global else { return }
        global = settings
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.globalKey)
        }
    }

    /// Applies one field from `settings` to either scope.
    func update(
        _ key: String,
        from settings: MangaReaderSettings,
        documentID: String?
    ) {
        guard let values = Self.dictionary(from: settings),
              let value = values[key] else {
            return
        }
        if let documentID {
            var titleOverrides = overrides[documentID] ?? [:]
            titleOverrides[key] = value
            overrides[documentID] = titleOverrides
            scheduleOverridesWrite()
        } else {
            guard var globalValues = Self.dictionary(from: global) else { return }
            globalValues[key] = value
            if let next = Self.settings(from: globalValues) {
                updateGlobal(next)
            }
        }
    }

    func clearOverride(_ key: String, documentID: String) {
        guard overrides[documentID]?[key] != nil else { return }
        overrides[documentID]?[key] = nil
        if overrides[documentID]?.isEmpty == true {
            overrides[documentID] = nil
        }
        scheduleOverridesWrite()
    }

    func clearOverrides(documentID: String) {
        guard overrides[documentID] != nil else { return }
        overrides[documentID] = nil
        scheduleOverridesWrite()
    }

    func flush() async {
        await writeTask?.value
    }

    private func scheduleOverridesWrite() {
        guard JSONSerialization.isValidJSONObject(overrides),
              let data = try? JSONSerialization.data(
                  withJSONObject: overrides,
                  options: [.sortedKeys]
              ) else {
            return
        }
        let url = overridesURL
        let previous = writeTask
        writeTask = Task.detached(priority: .utility) {
            await previous?.value
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func loadOverrides(from url: URL) -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data),
              let overrides = object as? [String: [String: Any]] else {
            return [:]
        }
        return overrides
    }

    private static func loadGlobal(from defaults: UserDefaults) -> MangaReaderSettings {
        if let data = defaults.data(forKey: globalKey),
           let settings = try? JSONDecoder().decode(MangaReaderSettings.self, from: data) {
            return settings
        }
        return migratedSettings(from: defaults)
    }

    /// Carries the reader options that existed before the settings panel into
    /// the new model so upgrading keeps every user's layout, direction, zoom,
    /// page processing and OCR choice.
    nonisolated static func migratedSettings(from defaults: UserDefaults) -> MangaReaderSettings {
        var settings = MangaReaderSettings()
        if let rawLayout = defaults.string(forKey: MangaReaderPreferences.layoutKey),
           let layout = MangaReaderLayout(rawValue: rawLayout) {
            switch layout {
            case .singlePage:
                settings.mode = .paged
                settings.spreadMode = .single
            case .doublePage:
                settings.mode = .paged
                settings.spreadMode = .double
            case .continuous:
                settings.mode = .continuous
            }
            // The previous double-page reader paired pages from the first
            // page; keep that pairing for existing readers.
            settings.showsCoverAlone = false
        }
        if defaults.object(forKey: MangaReaderPreferences.directionKey) != nil {
            settings.direction = MangaReaderPreferences.direction(in: defaults)
        }
        if defaults.object(forKey: MangaReaderPreferences.zoomLevelKey) != nil {
            settings.zoomPercentage = MangaReaderPreferences.zoomPercentage(in: defaults)
        }
        settings.splitsWidePages = MangaPageProcessingPreferences.splitsWidePages(in: defaults)
        settings.cropsBorders = MangaPageProcessingPreferences.cropsWhiteBorders(in: defaults)
        if MangaReaderPreferences.isOCREnabled(in: defaults) {
            // Existing OCR users recognized pages with Google Lens; keep that
            // engine so their cached pages stay valid.
            settings.ocrEngine = .googleLens
        }
        settings.normalize()
        return settings
    }

    nonisolated static func hasStoredLayout(in defaults: UserDefaults) -> Bool {
        defaults.data(forKey: globalKey) != nil
            || defaults.object(forKey: MangaReaderPreferences.layoutKey) != nil
    }

    nonisolated static func dictionary(from settings: MangaReaderSettings) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(settings),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        return object as? [String: Any]
    }

    nonisolated static func settings(from dictionary: [String: Any]) -> MangaReaderSettings? {
        guard JSONSerialization.isValidJSONObject(dictionary),
              let data = try? JSONSerialization.data(withJSONObject: dictionary) else {
            return nil
        }
        return try? JSONDecoder().decode(MangaReaderSettings.self, from: data)
    }
}
