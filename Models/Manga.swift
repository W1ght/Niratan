import Foundation
import CoreGraphics
import UniformTypeIdentifiers

nonisolated enum MangaLibrarySourceKind: String, Codable, Sendable {
    /// Legacy recursive library root retained for existing catalogs only.
    case folder
    /// One directly selected folder whose immediate image files form one manga.
    case imageFolder
    case mokuroFolder
    case archive
}

nonisolated struct MangaLibrarySource: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var path: String
    var bookmark: Data
    var kind: MangaLibrarySourceKind
    var lastScannedAt: Date?
    var lastError: String?

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        bookmark: Data,
        kind: MangaLibrarySourceKind,
        lastScannedAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.bookmark = bookmark
        self.kind = kind
        self.lastScannedAt = lastScannedAt
        self.lastError = lastError
    }
}

nonisolated enum MangaContainerKind: String, Codable, Sendable {
    case directory
    case zipArchive
    case epubArchive
}

nonisolated struct MangaLibraryItem: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let sourceID: UUID
    let relativePath: String
    let title: String
    var renamedTitle: String? = nil
    let containerKind: MangaContainerKind
    let pageCount: Int
    let modifiedAt: Date?
    var coverCachePath: String?
    var currentPageIndex: Int
    var lastReadAt: Date?

    var displayTitle: String {
        let trimmed = renamedTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.flatMap { $0.isEmpty ? nil : $0 } ?? title
    }

    var progress: Double {
        guard pageCount > 1 else { return currentPageIndex > 0 ? 1 : 0 }
        return Double(currentPageIndex) / Double(pageCount - 1)
    }
}

nonisolated struct MangaShelf: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var itemIDs: [String]

    init(id: UUID = UUID(), name: String, itemIDs: [String] = []) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
    }
}

nonisolated struct MangaLibraryCatalog: Codable, Equatable, Sendable {
    var sources: [MangaLibrarySource]
    var items: [MangaLibraryItem]
    var shelves: [MangaShelf]
    var manualItemOrder: [String]
    var hiddenItemIDs: Set<String>

    init(
        sources: [MangaLibrarySource],
        items: [MangaLibraryItem],
        shelves: [MangaShelf] = [],
        manualItemOrder: [String] = [],
        hiddenItemIDs: Set<String> = []
    ) {
        self.sources = sources
        self.items = items
        self.shelves = shelves
        self.manualItemOrder = manualItemOrder
        self.hiddenItemIDs = hiddenItemIDs
    }

    private enum CodingKeys: String, CodingKey {
        case sources
        case items
        case shelves
        case manualItemOrder
        case hiddenItemIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = try container.decodeIfPresent([MangaLibrarySource].self, forKey: .sources) ?? []
        items = try container.decodeIfPresent([MangaLibraryItem].self, forKey: .items) ?? []
        shelves = try container.decodeIfPresent([MangaShelf].self, forKey: .shelves) ?? []
        manualItemOrder = try container.decodeIfPresent([String].self, forKey: .manualItemOrder) ?? []
        hiddenItemIDs = try container.decodeIfPresent(Set<String>.self, forKey: .hiddenItemIDs) ?? []
    }

    static let empty = MangaLibraryCatalog(sources: [], items: [])
}

nonisolated enum MangaLibrarySortOption: String, CaseIterable, Identifiable, Sendable {
    case recent
    case title
    case manual

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .recent: "Recent"
        case .title: "Title"
        case .manual: "Manual"
        }
    }

    var icon: String {
        switch self {
        case .recent: "clock"
        case .title: "textformat.size.larger.ja"
        case .manual: "line.3.horizontal"
        }
    }
}

nonisolated enum MangaLibraryPreferences {
    static let sortOptionKey = "mangaLibrarySortOption"
    static let showReadingKey = "mangaLibraryShowReading"

    static func sortOption(in defaults: UserDefaults = .standard) -> MangaLibrarySortOption {
        defaults.string(forKey: sortOptionKey)
            .flatMap(MangaLibrarySortOption.init(rawValue:))
            ?? .manual
    }

    static func showReading(in defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showReadingKey) != nil else { return true }
        return defaults.bool(forKey: showReadingKey)
    }

    static func save(
        sortOption: MangaLibrarySortOption,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(sortOption.rawValue, forKey: sortOptionKey)
    }

    static func save(showReading: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(showReading, forKey: showReadingKey)
    }
}

nonisolated enum MangaReaderLayout: String, CaseIterable, Identifiable, Sendable {
    case singlePage
    case doublePage
    case continuous

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .singlePage: "Single Page"
        case .doublePage: "Double Page"
        case .continuous: "Continuous"
        }
    }

    var systemImage: String {
        switch self {
        case .singlePage: "rectangle.portrait"
        case .doublePage: "book.pages"
        case .continuous: "rectangle.stack"
        }
    }
}

nonisolated enum MangaReadingDirection: String, Codable, CaseIterable, Identifiable, Sendable {
    case rightToLeft
    case leftToRight

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .rightToLeft: "Right to Left"
        case .leftToRight: "Left to Right"
        }
    }

    var systemImage: String {
        switch self {
        case .rightToLeft: "text.alignright"
        case .leftToRight: "text.alignleft"
        }
    }
}

nonisolated enum MangaReaderPreferences {
    static let minimumZoomPercentage = 50
    static let maximumZoomPercentage = 200
    static let defaultZoomPercentage = 100
    static let layoutKey = "mangaReaderLayout"
    static let directionKey = "mangaReadingDirection"
    static let ocrEnabledKey = "mangaReaderOCREnabled"
    static let zoomLevelKey = "mangaReaderZoomLevel"

    static func layout(in defaults: UserDefaults = .standard) -> MangaReaderLayout {
        defaults.string(forKey: layoutKey)
            .flatMap(MangaReaderLayout.init(rawValue:))
            ?? .singlePage
    }

    static func direction(in defaults: UserDefaults = .standard) -> MangaReadingDirection {
        defaults.string(forKey: directionKey)
            .flatMap(MangaReadingDirection.init(rawValue:))
            ?? .rightToLeft
    }

    static func isOCREnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: ocrEnabledKey)
    }

    static func zoomPercentage(
        in defaults: UserDefaults = .standard
    ) -> Int {
        guard defaults.object(forKey: zoomLevelKey) != nil else {
            return defaultZoomPercentage
        }
        return clampedZoomPercentage(defaults.integer(forKey: zoomLevelKey))
    }

    static func save(
        layout: MangaReaderLayout,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(layout.rawValue, forKey: layoutKey)
    }

    static func save(
        direction: MangaReadingDirection,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(direction.rawValue, forKey: directionKey)
    }

    static func save(
        isOCREnabled: Bool,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(isOCREnabled, forKey: ocrEnabledKey)
    }

    static func save(
        zoomPercentage: Int,
        in defaults: UserDefaults = .standard
    ) {
        defaults.set(
            clampedZoomPercentage(zoomPercentage),
            forKey: zoomLevelKey
        )
    }

    static func clampedZoomPercentage(_ percentage: Int) -> Int {
        min(maximumZoomPercentage, max(minimumZoomPercentage, percentage))
    }
}

nonisolated enum MangaWheelNavigation: Equatable, Sendable {
    case backward
    case forward
}

nonisolated enum MangaWheelNavigationResolver {
    static func navigation(
        deltaX: Double,
        deltaY: Double,
        hasPreciseScrollingDeltas: Bool
    ) -> MangaWheelNavigation? {
        guard !hasPreciseScrollingDeltas,
              deltaY != 0,
              abs(deltaY) >= abs(deltaX) else {
            return nil
        }
        // AppKit's vertical scrolling delta is positive when content moves up,
        // the inverse of the WheelEvent delta used by the novel reader.
        return deltaY < 0 ? .forward : .backward
    }
}

nonisolated struct MangaWheelNavigationAccumulator {
    static let defaultThreshold = 1.0

    private var accumulatedDeltaY = 0.0

    mutating func consume(
        deltaX: Double,
        deltaY: Double,
        hasPreciseScrollingDeltas: Bool,
        threshold: Double = Self.defaultThreshold
    ) -> MangaWheelNavigation? {
        guard let navigation = MangaWheelNavigationResolver.navigation(
            deltaX: deltaX,
            deltaY: deltaY,
            hasPreciseScrollingDeltas: hasPreciseScrollingDeltas
        ) else {
            reset()
            return nil
        }

        if accumulatedDeltaY != 0,
           accumulatedDeltaY.sign != deltaY.sign {
            accumulatedDeltaY = 0
        }
        accumulatedDeltaY += deltaY
        guard abs(accumulatedDeltaY) >= threshold else {
            return nil
        }
        accumulatedDeltaY = 0
        return navigation
    }

    mutating func reset() {
        accumulatedDeltaY = 0
    }
}

nonisolated enum MangaWheelZoomResolver {
    static func scale(
        currentScale: Double,
        deltaX: Double,
        deltaY: Double,
        hasPreciseScrollingDeltas: Bool,
        minimumScale: Double = Double(MangaReaderPreferences.minimumZoomPercentage) / 100,
        maximumScale: Double = Double(MangaReaderPreferences.maximumZoomPercentage) / 100,
        sensitivityMultiplier: Double = 1
    ) -> Double? {
        let delta = abs(deltaY) >= abs(deltaX) ? deltaY : deltaX
        guard delta != 0 else { return nil }
        let sensitivity = (hasPreciseScrollingDeltas ? 0.012 : 0.12)
            * max(0.25, sensitivityMultiplier)
        return min(
            maximumScale,
            max(
                minimumScale,
                currentScale * Foundation.exp(delta * sensitivity)
            )
        )
    }
}

nonisolated struct MangaPageDescriptor: Equatable, Identifiable, Sendable {
    let index: Int
    let path: String

    var id: Int { index }
}

nonisolated struct MangaOCRTextRegion: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let pageIndex: Int
    let blockID: String
    let lineID: String
    let sentence: String
    let utf16Offset: Int
    let isVertical: Bool
    let normalizedBounds: CGRect

    private enum CodingKeys: String, CodingKey {
        case id
        case pageIndex
        case blockID
        case lineID
        case sentence
        case utf16Offset
        case isVertical
        case boundsX
        case boundsY
        case boundsWidth
        case boundsHeight
    }

    init(
        id: String,
        pageIndex: Int,
        blockID: String,
        lineID: String,
        sentence: String,
        utf16Offset: Int,
        isVertical: Bool,
        normalizedBounds: CGRect
    ) {
        self.id = id
        self.pageIndex = pageIndex
        self.blockID = blockID
        self.lineID = lineID
        self.sentence = sentence
        self.utf16Offset = utf16Offset
        self.isVertical = isVertical
        self.normalizedBounds = normalizedBounds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        pageIndex = try container.decode(Int.self, forKey: .pageIndex)
        blockID = try container.decode(String.self, forKey: .blockID)
        lineID = try container.decode(String.self, forKey: .lineID)
        sentence = try container.decode(String.self, forKey: .sentence)
        utf16Offset = try container.decode(Int.self, forKey: .utf16Offset)
        isVertical = try container.decode(Bool.self, forKey: .isVertical)
        normalizedBounds = CGRect(
            x: try container.decode(CGFloat.self, forKey: .boundsX),
            y: try container.decode(CGFloat.self, forKey: .boundsY),
            width: try container.decode(CGFloat.self, forKey: .boundsWidth),
            height: try container.decode(CGFloat.self, forKey: .boundsHeight)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(pageIndex, forKey: .pageIndex)
        try container.encode(blockID, forKey: .blockID)
        try container.encode(lineID, forKey: .lineID)
        try container.encode(sentence, forKey: .sentence)
        try container.encode(utf16Offset, forKey: .utf16Offset)
        try container.encode(isVertical, forKey: .isVertical)
        try container.encode(normalizedBounds.origin.x, forKey: .boundsX)
        try container.encode(normalizedBounds.origin.y, forKey: .boundsY)
        try container.encode(normalizedBounds.size.width, forKey: .boundsWidth)
        try container.encode(normalizedBounds.size.height, forKey: .boundsHeight)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
            && lhs.pageIndex == rhs.pageIndex
            && lhs.blockID == rhs.blockID
            && lhs.lineID == rhs.lineID
            && lhs.sentence == rhs.sentence
            && lhs.utf16Offset == rhs.utf16Offset
            && lhs.isVertical == rhs.isVertical
            && lhs.normalizedBounds.origin.x == rhs.normalizedBounds.origin.x
            && lhs.normalizedBounds.origin.y == rhs.normalizedBounds.origin.y
            && lhs.normalizedBounds.size.width == rhs.normalizedBounds.size.width
            && lhs.normalizedBounds.size.height == rhs.normalizedBounds.size.height
    }
}

nonisolated enum MangaOCRLanguage: String, Codable, Sendable {
    case japanese = "ja"
    case english = "en"

    var regionCode: String {
        switch self {
        case .japanese: "JP"
        case .english: "US"
        }
    }

    var timeZoneIdentifier: String {
        switch self {
        case .japanese: "Asia/Tokyo"
        case .english: "America/New_York"
        }
    }
}

nonisolated struct MangaOCRCacheKey: Hashable, Sendable {
    static let googleLensEngineID = "google-lens"
    static let googleLensEngineSignature = "google-lens-v2"

    let itemID: String
    let pageIndex: Int
    let pagePath: String
    let modifiedAt: Date?
    let language: MangaOCRLanguage
    /// Each engine keeps its own cache directory, so switching engines never
    /// discards another engine's completed pages.
    var engineID: String = Self.googleLensEngineID
    /// A changed signature (engine revision or model fingerprint) invalidates
    /// only that engine's pages.
    var engineSignature: String = Self.googleLensEngineSignature
}

nonisolated enum MangaMediaTypes {
    static let cbzContentType = UTType(
        importedAs: "moe.shishamo.hoshi.cbz-archive",
        conformingTo: .zip
    )
    static let importContentTypes: [UTType] = [
        .zip,
        .epub,
        cbzContentType,
    ]
    static let archiveExtensions: Set<String> = ["cbz", "epub", "zip"]
    static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg",
        "png", "tif", "tiff", "webp",
    ]

    static func isArchive(_ url: URL) -> Bool {
        archiveExtensions.contains(url.pathExtension.lowercased())
    }

    static func containerKind(for url: URL) -> MangaContainerKind? {
        switch url.pathExtension.lowercased() {
        case "cbz", "zip":
            .zipArchive
        case "epub":
            .epubArchive
        default:
            nil
        }
    }

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    static func isImagePath(_ path: String) -> Bool {
        imageExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }
}

nonisolated enum MangaPagePairResolver {
    static func indices(
        startingAt pageIndex: Int,
        pageCount: Int,
        direction: MangaReadingDirection
    ) -> [Int] {
        guard pageCount > 0 else { return [] }
        let first = min(max(0, pageIndex), pageCount - 1)
        let indices = [first, first + 1].filter { $0 < pageCount }
        return direction == .rightToLeft ? Array(indices.reversed()) : indices
    }
}
