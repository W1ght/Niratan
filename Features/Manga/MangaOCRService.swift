import Foundation
import ImageIO
import UniformTypeIdentifiers

// Chromium Lens protobuf interoperability follows the Google OCR approach used
// by 1Selxo/Mangatan (GPL-3.0), adapted here for Niratan's native Swift canvas.
nonisolated enum MangaOCRError: LocalizedError {
    case imageUnavailable
    case requestFailed
    case serviceUnavailable
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .imageUnavailable:
            String(localized: "The manga page could not be prepared for text recognition.")
        case .requestFailed:
            String(localized: "Google Lens text recognition failed. Check your internet connection and try again.")
        case .serviceUnavailable:
            String(localized: "Google Lens text recognition is temporarily unavailable.")
        case .invalidResponse:
            String(localized: "Google Lens returned an unreadable text recognition result.")
        }
    }
}

actor MangaOCRService {
    static let shared = MangaOCRService()

    private struct CacheManifest: Codable, Equatable {
        let schemaVersion: Int
        let engineSignature: String
        let language: MangaOCRLanguage
        let itemID: String
        let modifiedAt: Date?
        let pagePaths: [String]
    }

    private static let endpoint = URL(
        string: "https://lensfrontend-pa.googleapis.com/v1/crupload"
    )!
    private static let chromiumAPIKey = "AIzaSyDr2UxVnv_U85AbhhY8XSHSIavUW0DC-sY"
    private static let userAgent = """
        Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) \
        AppleWebKit/537.36 (KHTML, like Gecko) \
        Chrome/120.0.0.0 Safari/537.36
        """
    private static let maximumCachedPages = 24
    private static let maximumImageDimension = 1_500
    private static let maximumResponseBytes = 12 * 1_024 * 1_024
    private static let maximumCachedPageBytes = 32 * 1_024 * 1_024
    private static let maximumRegionsPerPage = 100_000
    private static let cacheSchemaVersion = 2

    private let session: URLSession
    private let cacheDirectory: URL
    private let fileManager: FileManager
    private var cache: [MangaOCRCacheKey: [MangaOCRTextRegion]] = [:]
    private var cacheOrder: [MangaOCRCacheKey] = []
    private var preparedManifests: [String: CacheManifest] = [:]

    init(
        session: URLSession? = nil,
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let applicationSupportDirectory = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        self.cacheDirectory = cacheDirectory
            ?? applicationSupportDirectory.appendingPathComponent(
                "MangaOCR",
                isDirectory: true
            )
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 60
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            configuration.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(configuration: configuration)
        }
    }

    func recognizeText(
        in data: Data,
        key: MangaOCRCacheKey,
        pagePaths: [String]
    ) async throws -> [MangaOCRTextRegion] {
        if let cached = cachedRegions(for: key, pagePaths: pagePaths) {
            return cached
        }

        let prepared = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try MangaGoogleLensProtocol.prepareImage(
                data,
                maximumDimension: Self.maximumImageDimension
            )
        }.value
        try Task.checkCancellation()

        var request = URLRequest(
            url: Self.endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        request.httpMethod = "POST"
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.chromiumAPIKey, forHTTPHeaderField: "X-Goog-Api-Key")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = MangaGoogleLensProtocol.makeRequest(
            imageData: prepared.data,
            width: prepared.width,
            height: prepared.height,
            language: key.language
        )

        let responseData: Data
        let response: URLResponse
        do {
            (responseData, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw MangaOCRError.requestFailed
        }
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw MangaOCRError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw MangaOCRError.serviceUnavailable
        }
        guard responseData.count <= Self.maximumResponseBytes else {
            throw MangaOCRError.invalidResponse
        }

        let regions: [MangaOCRTextRegion]
        do {
            regions = try MangaGoogleLensProtocol.decodeResponse(
                responseData,
                pageIndex: key.pageIndex,
                language: key.language
            )
        } catch {
            throw MangaOCRError.invalidResponse
        }
        try Task.checkCancellation()
        storeCachedRegions(regions, for: key, pagePaths: pagePaths)
        return regions
    }

    /// Recognizes a page with an on-device engine and caches the regions under
    /// that engine's signature. Nothing is uploaded.
    func recognizeText(
        in data: Data,
        key: MangaOCRCacheKey,
        pagePaths: [String],
        idPrefix: String,
        recognizer: @Sendable (Data) async throws -> MangaOCRPageResult
    ) async throws -> [MangaOCRTextRegion] {
        if let cached = cachedRegions(for: key, pagePaths: pagePaths) {
            return cached
        }
        let page = try await recognizer(data)
        try Task.checkCancellation()
        let regions = MangaOCRRegionBuilder.regions(
            from: page,
            pageIndex: key.pageIndex,
            idPrefix: idPrefix
        )
        storeCachedRegions(regions, for: key, pagePaths: pagePaths)
        return regions
    }

    func cachedRegions(
        for key: MangaOCRCacheKey,
        pagePaths: [String]
    ) -> [MangaOCRTextRegion]? {
        guard pagePaths.indices.contains(key.pageIndex),
              pagePaths[key.pageIndex] == key.pagePath else {
            return nil
        }

        let itemDirectory = try? prepareCache(for: key, pagePaths: pagePaths)
        if let cached = cache[key] {
            touch(key)
            return cached
        }
        guard let itemDirectory else { return nil }

        let pageURL = pageCacheURL(
            pageIndex: key.pageIndex,
            in: itemDirectory
        )
        guard let values = try? pageURL.resourceValues(forKeys: [.fileSizeKey]),
              let fileSize = values.fileSize,
              fileSize <= Self.maximumCachedPageBytes,
              let data = try? Data(contentsOf: pageURL, options: [.mappedIfSafe]),
              let regions = try? JSONDecoder().decode(
                  [MangaOCRTextRegion].self,
                  from: data
              ),
              isValid(regions, pageIndex: key.pageIndex) else {
            return nil
        }
        cache[key] = regions
        touch(key)
        trimCacheIfNeeded()
        return regions
    }

    func storeCachedRegions(
        _ regions: [MangaOCRTextRegion],
        for key: MangaOCRCacheKey,
        pagePaths: [String]
    ) {
        guard pagePaths.indices.contains(key.pageIndex),
              pagePaths[key.pageIndex] == key.pagePath,
              isValid(regions, pageIndex: key.pageIndex) else {
            return
        }
        let itemDirectory = try? prepareCache(for: key, pagePaths: pagePaths)
        cache[key] = regions
        touch(key)
        trimCacheIfNeeded()

        guard let itemDirectory,
        let data = try? JSONEncoder().encode(regions),
        data.count <= Self.maximumCachedPageBytes else {
            return
        }
        try? data.write(
            to: pageCacheURL(pageIndex: key.pageIndex, in: itemDirectory),
            options: .atomic
        )
    }

    func clear(itemID: String) {
        cache = cache.filter { $0.key.itemID != itemID }
        cacheOrder.removeAll { $0.itemID == itemID }
        preparedManifests = preparedManifests.filter {
            !$0.key.hasPrefix("\(itemID)\u{1f}")
        }
        try? fileManager.removeItem(
            at: cacheDirectory.appendingPathComponent(
                Self.safeCacheName(for: itemID),
                isDirectory: true
            )
        )
    }

    /// Removes one engine's cached pages for an item ("re-run OCR").
    func clear(itemID: String, engineID: String, language: MangaOCRLanguage) {
        let directoryName = Self.cacheDirectoryName(engineID: engineID, language: language)
        cache = cache.filter {
            !($0.key.itemID == itemID && $0.key.engineID == engineID && $0.key.language == language)
        }
        cacheOrder.removeAll {
            $0.itemID == itemID && $0.engineID == engineID && $0.language == language
        }
        preparedManifests["\(itemID)\u{1f}\(directoryName)"] = nil
        try? fileManager.removeItem(
            at: cacheDirectory
                .appendingPathComponent(Self.safeCacheName(for: itemID), isDirectory: true)
                .appendingPathComponent(directoryName, isDirectory: true)
        )
    }

    /// Google Lens keeps its original per-language directory; other engines
    /// use `<engine>-<language>` beside it.
    private static func cacheDirectoryName(
        engineID: String,
        language: MangaOCRLanguage
    ) -> String {
        engineID == MangaOCRCacheKey.googleLensEngineID
            ? language.rawValue
            : "\(engineID)-\(language.rawValue)"
    }

    private func prepareCache(
        for key: MangaOCRCacheKey,
        pagePaths: [String]
    ) throws -> URL {
        let itemID = key.itemID
        let modifiedAt = key.modifiedAt
        let language = key.language
        let directoryName = Self.cacheDirectoryName(
            engineID: key.engineID,
            language: language
        )
        let expectedManifest = CacheManifest(
            schemaVersion: Self.cacheSchemaVersion,
            engineSignature: key.engineSignature,
            language: language,
            itemID: itemID,
            modifiedAt: modifiedAt,
            pagePaths: pagePaths
        )
        let itemRootDirectory = cacheDirectory.appendingPathComponent(
            Self.safeCacheName(for: itemID),
            isDirectory: true
        )
        let legacyManifestURL = itemRootDirectory.appendingPathComponent(
            "manifest.json"
        )
        if fileManager.fileExists(atPath: legacyManifestURL.path) {
            try? fileManager.removeItem(at: itemRootDirectory)
            cache = cache.filter { $0.key.itemID != itemID }
            cacheOrder.removeAll { $0.itemID == itemID }
            preparedManifests = preparedManifests.filter {
                !$0.key.hasPrefix("\(itemID)\u{1f}")
            }
        }
        let itemDirectory = itemRootDirectory.appendingPathComponent(
            directoryName,
            isDirectory: true
        )
        let manifestIdentity = "\(itemID)\u{1f}\(directoryName)"
        if preparedManifests[manifestIdentity] == expectedManifest,
           fileManager.fileExists(atPath: itemDirectory.path) {
            return itemDirectory
        }

        let manifestURL = itemDirectory.appendingPathComponent("manifest.json")
        let existingManifest: CacheManifest?
        if let data = try? Data(
            contentsOf: manifestURL,
            options: [.mappedIfSafe]
        ) {
            existingManifest = try? JSONDecoder().decode(
                CacheManifest.self,
                from: data
            )
        } else {
            existingManifest = nil
        }
        if existingManifest != expectedManifest {
            try? fileManager.removeItem(at: itemDirectory)
            cache = cache.filter {
                !($0.key.itemID == itemID && $0.key.engineID == key.engineID
                    && $0.key.language == language)
            }
            cacheOrder.removeAll {
                $0.itemID == itemID && $0.engineID == key.engineID
                    && $0.language == language
            }
        }

        try fileManager.createDirectory(
            at: itemDirectory,
            withIntermediateDirectories: true
        )
        if existingManifest != expectedManifest
            || !fileManager.fileExists(atPath: manifestURL.path) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(expectedManifest).write(
                to: manifestURL,
                options: .atomic
            )
        }
        preparedManifests[manifestIdentity] = expectedManifest
        return itemDirectory
    }

    private func pageCacheURL(pageIndex: Int, in itemDirectory: URL) -> URL {
        itemDirectory.appendingPathComponent(
            String(format: "%06d.json", pageIndex)
        )
    }

    private func isValid(
        _ regions: [MangaOCRTextRegion],
        pageIndex: Int
    ) -> Bool {
        guard regions.count <= Self.maximumRegionsPerPage else { return false }
        return regions.allSatisfy { region in
            let bounds = region.normalizedBounds
            return region.pageIndex == pageIndex
                && region.utf16Offset >= 0
                && region.utf16Offset <= region.sentence.utf16.count
                && bounds.origin.x.isFinite
                && bounds.origin.y.isFinite
                && bounds.size.width.isFinite
                && bounds.size.height.isFinite
                && bounds.size.width >= 0
                && bounds.size.height >= 0
        }
    }

    private static func safeCacheName(for value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private func touch(_ key: MangaOCRCacheKey) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    private func trimCacheIfNeeded() {
        while cacheOrder.count > Self.maximumCachedPages {
            cache[cacheOrder.removeFirst()] = nil
        }
    }
}

nonisolated enum MangaGoogleLensProtocol {
    struct PreparedImage: Sendable {
        let data: Data
        let width: Int
        let height: Int
    }

    private struct Geometry {
        let rect: CGRect
        let rotation: CGFloat

        var isVertical: Bool {
            abs(abs(rotation) - .pi / 2) < 0.5
                || rect.height > rect.width * 1.25
        }
    }

    private struct RecognizedLine {
        let sourceIndex: Int
        let text: String
        let geometry: Geometry
    }

    static func prepareImage(
        _ data: Data,
        maximumDimension: Int
    ) throws -> PreparedImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                ] as CFDictionary
              ) else {
            throw MangaOCRError.imageUnavailable
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw MangaOCRError.imageUnavailable
        }
        CGImageDestinationAddImage(
            destination,
            image,
            [
                kCGImageDestinationLossyCompressionQuality: 0.92,
                kCGImagePropertyOrientation: 1,
            ] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw MangaOCRError.imageUnavailable
        }
        return PreparedImage(
            data: output as Data,
            width: image.width,
            height: image.height
        )
    }

    static func makeRequest(
        imageData: Data,
        width: Int,
        height: Int,
        language: MangaOCRLanguage
    ) -> Data {
        var root = ProtobufWriter()
        root.message(field: 1) { objects in
            objects.message(field: 1) { context in
                context.message(field: 3) { requestID in
                    requestID.uint(field: 1, value: UInt64.random(in: 1...UInt64.max / 2))
                    requestID.uint(field: 2, value: 1)
                    requestID.uint(field: 3, value: 1)
                }
                context.message(field: 4) { client in
                    client.uint(field: 1, value: 3)
                    client.uint(field: 2, value: 4)
                    client.message(field: 4) { locale in
                        locale.string(field: 1, value: language.rawValue)
                        locale.string(field: 2, value: language.regionCode)
                        locale.string(
                            field: 3,
                            value: language.timeZoneIdentifier
                        )
                    }
                }
            }
            objects.message(field: 3) { image in
                image.message(field: 1) { payload in
                    payload.bytes(field: 1, value: imageData)
                }
                image.message(field: 3) { metadata in
                    metadata.uint(field: 1, value: UInt64(width))
                    metadata.uint(field: 2, value: UInt64(height))
                }
            }
        }
        return root.data
    }

    static func decodeResponse(
        _ data: Data,
        pageIndex: Int,
        language: MangaOCRLanguage
    ) throws -> [MangaOCRTextRegion] {
        let root = try ProtobufMessage(data: data)
        let paragraphs = try root
            .firstMessage(field: 2)?
            .firstMessage(field: 3)?
            .firstMessage(field: 1)?
            .messages(field: 1) ?? []
        var regions: [MangaOCRTextRegion] = []

        for (paragraphIndex, paragraph) in paragraphs.enumerated() {
            var lines: [RecognizedLine] = []
            for (lineIndex, line) in try paragraph.messages(field: 2).enumerated() {
                let words = try line.messages(field: 1)
                let rawText = try words.map {
                    try $0.string(field: 2) + $0.string(field: 3)
                }.joined()
                let text = normalize(rawText, language: language)
                guard !text.isEmpty,
                      let geometryMessage = try line.firstMessage(field: 2),
                      let geometry = try readGeometry(geometryMessage) else {
                    continue
                }
                lines.append(RecognizedLine(
                    sourceIndex: lineIndex,
                    text: text,
                    geometry: geometry
                ))
            }
            guard !lines.isEmpty else { continue }

            let paragraphGeometry = try paragraph
                .firstMessage(field: 3)
                .flatMap { try readGeometry($0) }
            let isVertical = paragraphGeometry?.isVertical == true
                || lines.filter(\.geometry.isVertical).count * 2 > lines.count
            lines.sort { lhs, rhs in
                if isVertical {
                    if abs(lhs.geometry.rect.midX - rhs.geometry.rect.midX) > 0.002 {
                        return lhs.geometry.rect.midX > rhs.geometry.rect.midX
                    }
                    return lhs.geometry.rect.maxY > rhs.geometry.rect.maxY
                }
                if abs(lhs.geometry.rect.maxY - rhs.geometry.rect.maxY) > 0.002 {
                    return lhs.geometry.rect.maxY > rhs.geometry.rect.maxY
                }
                return lhs.geometry.rect.minX < rhs.geometry.rect.minX
            }

            let lineSeparator = language == .english ? " " : ""
            let sentence = lines.map(\.text).joined(separator: lineSeparator)
            let blockID = "lens-\(pageIndex)-\(paragraphIndex)"
            var utf16BaseOffset = 0
            for (lineIndex, line) in lines.enumerated() {
                if lineIndex > 0 {
                    utf16BaseOffset += lineSeparator.utf16.count
                }
                let lineID = "\(blockID)-\(line.sourceIndex)"
                regions.append(contentsOf: makeCharacterRegions(
                    lineText: line.text,
                    sentence: sentence,
                    utf16BaseOffset: utf16BaseOffset,
                    geometry: line.geometry,
                    isVertical: isVertical,
                    pageIndex: pageIndex,
                    blockID: blockID,
                    lineID: lineID
                ))
                utf16BaseOffset += line.text.utf16.count
            }
        }
        return regions
    }

    static func requestLanguage(from data: Data) throws -> String {
        try ProtobufMessage(data: data)
            .firstMessage(field: 1)?
            .firstMessage(field: 1)?
            .firstMessage(field: 4)?
            .firstMessage(field: 4)?
            .string(field: 1) ?? ""
    }

    private static func normalize(
        _ text: String,
        language: MangaOCRLanguage
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard language == .japanese else {
            return trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return trimmed.filter { !$0.isWhitespace }
    }

    private static func readGeometry(_ message: ProtobufMessage) throws -> Geometry? {
        guard let box = try message.firstMessage(field: 1),
              let centerX = box.float32(field: 1),
              let centerY = box.float32(field: 2),
              let width = box.float32(field: 3),
              let height = box.float32(field: 4),
              width > 0,
              height > 0 else {
            return nil
        }
        let rotation = CGFloat(box.float32(field: 5) ?? 0)
        let cosine = abs(cos(rotation))
        let sine = abs(sin(rotation))
        let halfWidth = (CGFloat(width) * cosine + CGFloat(height) * sine) / 2
        let halfHeight = (CGFloat(width) * sine + CGFloat(height) * cosine) / 2
        let left = max(0, CGFloat(centerX) - halfWidth)
        let top = max(0, CGFloat(centerY) - halfHeight)
        let right = min(1, CGFloat(centerX) + halfWidth)
        let bottom = min(1, CGFloat(centerY) + halfHeight)
        guard right > left, bottom > top else { return nil }
        return Geometry(
            rect: CGRect(
                x: left,
                y: 1 - bottom,
                width: right - left,
                height: bottom - top
            ),
            rotation: rotation
        )
    }

    private static func makeCharacterRegions(
        lineText: String,
        sentence: String,
        utf16BaseOffset: Int,
        geometry: Geometry,
        isVertical: Bool,
        pageIndex: Int,
        blockID: String,
        lineID: String
    ) -> [MangaOCRTextRegion] {
        let characters = lineText.indices.map { index in
            (
                offset: utf16BaseOffset + lineText[..<index].utf16.count,
                character: lineText[index]
            )
        }.filter { !$0.character.isWhitespace }
        guard !characters.isEmpty else { return [] }

        let count = CGFloat(characters.count)
        return characters.enumerated().map { index, character in
            let bounds: CGRect
            if isVertical {
                let characterHeight = geometry.rect.height / count
                bounds = CGRect(
                    x: geometry.rect.minX,
                    y: geometry.rect.maxY - CGFloat(index + 1) * characterHeight,
                    width: geometry.rect.width,
                    height: characterHeight
                )
            } else {
                let characterWidth = geometry.rect.width / count
                bounds = CGRect(
                    x: geometry.rect.minX + CGFloat(index) * characterWidth,
                    y: geometry.rect.minY,
                    width: characterWidth,
                    height: geometry.rect.height
                )
            }
            return MangaOCRTextRegion(
                id: "\(lineID)-\(character.offset)",
                pageIndex: pageIndex,
                blockID: blockID,
                lineID: lineID,
                sentence: sentence,
                utf16Offset: character.offset,
                isVertical: isVertical,
                normalizedBounds: bounds
            )
        }
    }
}

nonisolated private struct ProtobufWriter {
    private(set) var data = Data()

    mutating func uint(field: Int, value: UInt64) {
        writeVarint(UInt64(field << 3))
        writeVarint(value)
    }

    mutating func string(field: Int, value: String) {
        bytes(field: field, value: Data(value.utf8))
    }

    mutating func bytes(field: Int, value: Data) {
        writeVarint(UInt64((field << 3) | 2))
        writeVarint(UInt64(value.count))
        data.append(value)
    }

    mutating func message(
        field: Int,
        build: (inout ProtobufWriter) -> Void
    ) {
        var nested = ProtobufWriter()
        build(&nested)
        bytes(field: field, value: nested.data)
    }

    private mutating func writeVarint(_ value: UInt64) {
        var remaining = value
        while remaining > 0x7f {
            data.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
    }
}

nonisolated private struct ProtobufMessage {
    private struct Field {
        let wireType: UInt64
        let value: Data
    }

    private let fields: [Int: [Field]]

    init(data: Data) throws {
        var cursor = ProtobufCursor(data: data)
        var decoded: [Int: [Field]] = [:]
        while !cursor.isAtEnd {
            let tag = try cursor.varint()
            let field = Int(tag >> 3)
            let wireType = tag & 7
            guard field > 0 else { throw MangaOCRError.invalidResponse }
            let value: Data
            switch wireType {
            case 0:
                _ = try cursor.varint()
                value = Data()
            case 1:
                value = try cursor.read(count: 8)
            case 2:
                let count = try cursor.varint()
                guard count <= UInt64(Int.max) else {
                    throw MangaOCRError.invalidResponse
                }
                value = try cursor.read(count: Int(count))
            case 5:
                value = try cursor.read(count: 4)
            default:
                throw MangaOCRError.invalidResponse
            }
            decoded[field, default: []].append(Field(wireType: wireType, value: value))
        }
        fields = decoded
    }

    func messages(field: Int) throws -> [ProtobufMessage] {
        try (fields[field] ?? [])
            .filter { $0.wireType == 2 }
            .map { try ProtobufMessage(data: $0.value) }
    }

    func firstMessage(field: Int) throws -> ProtobufMessage? {
        try messages(field: field).first
    }

    func string(field: Int) throws -> String {
        guard let value = fields[field]?.first(where: { $0.wireType == 2 })?.value else {
            return ""
        }
        guard let string = String(data: value, encoding: .utf8) else {
            throw MangaOCRError.invalidResponse
        }
        return string
    }

    func float32(field: Int) -> Float? {
        guard let value = fields[field]?.first(where: { $0.wireType == 5 })?.value,
              value.count == 4 else {
            return nil
        }
        let bits = value.withUnsafeBytes { bytes in
            bytes.loadUnaligned(as: UInt32.self)
        }
        return Float(bitPattern: UInt32(littleEndian: bits))
    }
}

nonisolated private struct ProtobufCursor {
    let data: Data
    private(set) var offset = 0

    var isAtEnd: Bool { offset >= data.count }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count, shift < 70 {
            let byte = data[offset]
            offset += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 {
                return result
            }
            shift += 7
        }
        throw MangaOCRError.invalidResponse
    }

    mutating func read(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else {
            throw MangaOCRError.invalidResponse
        }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }
}
