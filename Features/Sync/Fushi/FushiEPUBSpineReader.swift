//
//  FushiEPUBSpineReader.swift
//  Niratan
//
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import ZIPFoundation

nonisolated enum FushiEPUBSpineReaderError: Error {
    case missingPackage
    case invalidPackage
}

/// Reads an EPUB's spine straight from the stored archive (or an unpacked
/// folder) to rebuild Fushi's chapter list, without extracting anything:
/// `BookStorage.loadEpub` reuses a shared Temp directory that an open Reader
/// may be using.
nonisolated enum FushiEPUBSpineReader {
    private static let maximumDocumentBytes = 8 * 1024 * 1024

    /// Niratan spine indices of the items Fushi counts as chapters. Spine order
    /// matches EPUBKit: one entry per itemref that has an `idref`.
    static func sectionSpineIndices(epubURL: URL) throws -> [Int] {
        var isDirectory: ObjCBool = false
        let path = epubURL.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw FushiEPUBSpineReaderError.missingPackage
        }
        if isDirectory.boolValue {
            return try sectionSpineIndices(
                read: { try? Data(contentsOf: epubURL.appendingPathComponent($0)) },
                exists: { FileManager.default.fileExists(atPath: epubURL.appendingPathComponent($0).path(percentEncoded: false)) }
            )
        }
        let archive = try Archive(url: epubURL, accessMode: .read)
        let entries = Set(archive.compactMap { $0.type == .file ? $0.path : nil })
        let lowercasedEntries = Set(entries.map { $0.lowercased() })
        return try sectionSpineIndices(
            read: { path in
                guard let entry = archive[path],
                      entry.type == .file,
                      entry.uncompressedSize <= UInt64(maximumDocumentBytes) else {
                    return nil
                }
                var data = Data()
                data.reserveCapacity(Int(entry.uncompressedSize))
                _ = try archive.extract(entry) { data.append($0) }
                return data
            },
            exists: { entries.contains($0) || lowercasedEntries.contains($0.lowercased()) }
        )
    }

    static func sectionSpineIndices(
        read: (String) throws -> Data?,
        exists: (String) -> Bool
    ) throws -> [Int] {
        guard let containerData = try read("META-INF/container.xml") else {
            throw FushiEPUBSpineReaderError.missingPackage
        }
        let container = ContainerDelegate()
        try parse(containerData, delegate: container)
        guard let rootFile = container.packagePath,
              let packagePath = resolve(rootFile, relativeTo: ""),
              let packageData = try read(packagePath) else {
            throw FushiEPUBSpineReaderError.missingPackage
        }
        let package = PackageDelegate(packagePath: packagePath)
        try parse(packageData, delegate: package)
        guard !package.spineItemIDs.isEmpty else {
            throw FushiEPUBSpineReaderError.invalidPackage
        }

        var sections: [Int] = []
        for (spineIndex, idref) in package.spineItemIDs.enumerated() {
            guard let item = package.items[idref],
                  isHTMLMediaType(item.mediaType),
                  let itemPath = item.path,
                  exists(itemPath) else {
                continue
            }
            sections.append(spineIndex)
        }
        return sections
    }

    /// Fushi's `isHtmlMediaType`.
    static func isHTMLMediaType(_ mediaType: String) -> Bool {
        let lower = mediaType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower == "application/xhtml+xml" || lower == "text/html" || lower.hasSuffix("+html")
    }

    static func resolve(_ reference: String, relativeTo documentPath: String) -> String? {
        let withoutFragment = reference.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? reference
        let decoded = withoutFragment.removingPercentEncoding ?? withoutFragment
        let trimmed = decoded.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("://") else { return nil }

        let base = NSString(string: documentPath).deletingLastPathComponent
        let combined = (trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : NSString(string: base).appendingPathComponent(trimmed))
            .replacingOccurrences(of: "\\", with: "/")
        var components: [Substring] = []
        for component in combined.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(component)
            }
        }
        return components.isEmpty ? nil : components.joined(separator: "/")
    }

    private static func parse(_ data: Data, delegate: XMLParserDelegate) throws {
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw parser.parserError ?? FushiEPUBSpineReaderError.invalidPackage
        }
    }
}

nonisolated private final class ContainerDelegate: NSObject, XMLParserDelegate {
    var packagePath: String?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        guard packagePath == nil, elementName.lowercased() == "rootfile" else { return }
        packagePath = attributeDict["full-path"]
    }
}

nonisolated private final class PackageDelegate: NSObject, XMLParserDelegate {
    struct Item {
        let path: String?
        let mediaType: String
    }

    private let packagePath: String
    private var inSpine = false
    var items: [String: Item] = [:]
    var spineItemIDs: [String] = []

    init(packagePath: String) {
        self.packagePath = packagePath
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName.lowercased() {
        case "item":
            guard let id = attributeDict["id"] else { return }
            items[id] = Item(
                path: attributeDict["href"].flatMap { FushiEPUBSpineReader.resolve($0, relativeTo: packagePath) },
                mediaType: attributeDict["media-type"] ?? ""
            )
        case "spine":
            inSpine = true
        case "itemref":
            guard inSpine, let idref = attributeDict["idref"] else { return }
            spineItemIDs.append(idref)
        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName.lowercased() == "spine" {
            inSpine = false
        }
    }
}
