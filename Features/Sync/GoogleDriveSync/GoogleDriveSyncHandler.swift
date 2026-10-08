//
//  GoogleDriveSyncHandler.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

nonisolated struct GoogleDriveFile: Codable, Equatable, Sendable {
    var id: String
    var name: String
    var mimeType: String
    var md5Checksum: String?
    var size: String?
    var parents: [String]?
    var trashed: Bool?
    var createdTime: String

    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }

    var isRecent: Bool { (try? Date(createdTime, strategy: .iso8601)).map { Date.now.timeIntervalSince($0) < 86400 } ?? false }

    var stateKey: String? { name.hasSuffix(".json") && !isFolder ? String(name.dropLast(5)).precomposedStringWithCanonicalMapping : nil }
}

nonisolated struct GoogleDriveFileList: Decodable {
    var files: [GoogleDriveFile]
    var nextPageToken: String?
}

nonisolated struct GoogleDriveChanges: Decodable {
    struct Change: Decodable {
        var removed: Bool
        var file: GoogleDriveFile?
    }

    var changes: [Change]
    var nextPageToken: String?
    var newStartPageToken: String?
}

@MainActor
final class GoogleDriveSyncHandler {
    static let shared = GoogleDriveSyncHandler()
    /// The same library root used by Hoshi Reader; ッツ/ttu retains its own layout.
    static let rootFolderName = GoogleDriveSyncCache.sharedLibraryName
    private let client = GoogleDriveClient.shared
    private let fileFields = "id,name,mimeType,md5Checksum,size,parents,trashed,createdTime"

    func startToken() async throws -> String {
        struct Token: Decodable {
            var startPageToken: String
        }

        let data = try await client.request("changes/startPageToken")
        return try JSONDecoder().decode(Token.self, from: data).startPageToken
    }

    func changes(cursor: String) async throws -> GoogleDriveChanges {
        let data = try await client.request(
            "changes",
            query: [
                URLQueryItem(name: "pageToken", value: cursor),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "spaces", value: "drive"),
                URLQueryItem(name: "includeRemoved", value: "true"),
                URLQueryItem(name: "fields", value: "nextPageToken,newStartPageToken,changes(removed,file(\(fileFields)))")
            ]
        )
        return try JSONDecoder().decode(GoogleDriveChanges.self, from: data)
    }

    func layout() async throws -> (root: String, state: String, books: String) {
        // A different OAuth project cannot see Hoshi's drive.file library. Creating another
        // folder with the same name would silently reproduce the original split-library bug.
        guard let root = try await folder(parent: "root", name: Self.rootFolderName, create: false) else {
            throw GoogleDriveError.apiError(
                String(localized: "The Hoshi Reader library is not accessible. Sync once in Hoshi Reader, then sign in again with the same Google account."),
                statusCode: nil
            )
        }
        guard let state = try await folder(parent: root, name: "state", create: true),
              let books = try await folder(parent: root, name: "books", create: true) else {
            throw GoogleDriveError.invalidResponse
        }
        return (root, state, books)
    }

    func folder(parent: String, name: String, create: Bool) async throws -> String? {
        if let folder = try await children(parent: parent, name: name).first(where: \.isFolder) {
            return folder.id
        }
        if !create {
            return nil
        }
        return try await createFolder(parent: parent, name: name)
    }

    func createFolder(parent: String, name: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: [
            "name": name,
            "parents": [parent],
            "mimeType": "application/vnd.google-apps.folder"
        ])
        let data = try await client.request("files", query: [URLQueryItem(name: "fields", value: fileFields)], method: "POST", body: body)
        return try JSONDecoder().decode(GoogleDriveFile.self, from: data).id
    }

    func children(parent: String, name: String? = nil) async throws -> [GoogleDriveFile] {
        var query = "'\(escape(parent))' in parents"
        if let name {
            query += " and name='\(escape(name))'"
        }
        return try await list(query: query)
    }

    /// Batch only the shared library's direct children. A cross-app authorization must not
    /// turn the old app-scoped listing into a scan of unrelated files in the user's Drive.
    func children(parents: [String]) async throws -> [GoogleDriveFile] {
        var result: [GoogleDriveFile] = []
        let parents = Array(Set(parents)).sorted()
        for start in stride(from: 0, to: parents.count, by: 50) {
            let batch = parents[start..<min(start + 50, parents.count)]
            let query = batch.map { "'\(escape($0))' in parents" }.joined(separator: " or ")
            result += try await list(query: query)
        }
        return result.sorted { $0.id < $1.id }
    }

    func list(query: String) async throws -> [GoogleDriveFile] {
        var result: [GoogleDriveFile] = []
        var cursor: String?

        repeat {
            var items = [
                URLQueryItem(name: "q", value: "trashed=false and (\(query))"),
                URLQueryItem(name: "pageSize", value: "1000"),
                URLQueryItem(name: "spaces", value: "drive"),
                URLQueryItem(name: "fields", value: "nextPageToken,files(\(fileFields))")
            ]
            if let cursor {
                items.append(URLQueryItem(name: "pageToken", value: cursor))
            }

            let data = try await client.request("files", query: items)
            let page = try JSONDecoder().decode(GoogleDriveFileList.self, from: data)
            result.append(contentsOf: page.files)
            cursor = page.nextPageToken
        } while cursor != nil
        return result.sorted { $0.id < $1.id }
    }

    func read(_ file: GoogleDriveFile) async throws -> Data {
        try await client.request("files/\(file.id)", query: [URLQueryItem(name: "alt", value: "media")])
    }

    func upload(file: URL, fileName: String, folder: String) async throws {
        let existing = try await children(parent: folder, name: fileName)
        if !existing.isEmpty {
            return
        }
        try await client.write(file: file, name: fileName, parent: folder)
    }

    func download(_ file: GoogleDriveFile, onProgress: @MainActor @Sendable @escaping (Double) -> Void) async throws -> Data {
        try await client.downloadFile(fileId: file.id, fileSize: file.size.flatMap(Int64.init) ?? 0, onProgress: onProgress)
    }

    func trash(_ file: GoogleDriveFile) async throws {
        try await client.trashFile(fileId: file.id)
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
    }
}
