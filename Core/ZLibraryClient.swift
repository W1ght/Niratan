//
//  ZLibraryClient.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation
import Security

nonisolated struct ZLibrarySession: Codable, Equatable, Sendable {
    let baseOrigin: String
    let userID: String
    let userKey: String
}

nonisolated struct ZLibrarySearchRequest: Equatable, Sendable {
    var query: String
    var page = 1
    var limit = 20
    var yearFrom: Int?
    var yearTo: Int?
    var languages: [String] = []
    var extensions: [String] = ["EPUB"]
    var exact = false

    var formItems: [URLQueryItem] {
        var items = [
            URLQueryItem(name: "message", value: query),
            URLQueryItem(name: "page", value: String(max(page, 1))),
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), 50)))
        ]
        if let yearFrom {
            items.append(URLQueryItem(name: "yearFrom", value: String(yearFrom)))
        }
        if let yearTo {
            items.append(URLQueryItem(name: "yearTo", value: String(yearTo)))
        }
        items.append(contentsOf: languages.map { URLQueryItem(name: "languages[]", value: $0) })
        items.append(contentsOf: extensions.map { URLQueryItem(name: "extensions[]", value: $0.uppercased()) })
        if exact {
            items.append(URLQueryItem(name: "e", value: "1"))
        }
        return items
    }
}

nonisolated struct ZLibraryBook: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let hash: String
    let title: String
    let author: String
    let year: String
    let language: String
    let fileExtension: String
    let fileSize: String
    let coverURL: URL?
    let rating: String
    let isbn: String

    var isEPUB: Bool { fileExtension.caseInsensitiveCompare("epub") == .orderedSame }

    var fileSizeBytes: Int64? {
        let compact = fileSize
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let bytes = Int64(compact), bytes >= 0 { return bytes }

        let parts = compact.uppercased().split(whereSeparator: \Character.isWhitespace)
        guard let numberPart = parts.first,
              let value = Double(numberPart),
              value >= 0 else { return nil }
        let multiplier: Double
        switch parts.dropFirst().first {
        case "KB", "KIB": multiplier = 1_024
        case "MB", "MIB": multiplier = 1_048_576
        case "GB", "GIB": multiplier = 1_073_741_824
        case "B", .none: multiplier = 1
        default: return nil
        }
        let bytes = value * multiplier
        guard bytes <= Double(Int64.max) else { return nil }
        return Int64(bytes.rounded())
    }

    private enum CodingKeys: String, CodingKey {
        case id, hash, title, author, year, language, extensionName = "extension"
        case fileSize = "filesize"
        case cover, rating, isbn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lossyString(forKey: .id)
        hash = container.lossyString(forKey: .hash)
        title = container.lossyString(forKey: .title)
        author = container.lossyString(forKey: .author)
        year = container.lossyString(forKey: .year)
        language = container.lossyString(forKey: .language)
        fileExtension = container.lossyString(forKey: .extensionName)
        fileSize = container.lossyString(forKey: .fileSize)
        rating = container.lossyString(forKey: .rating)
        isbn = container.lossyString(forKey: .isbn)
        if let url = URL(string: container.lossyString(forKey: .cover)),
           url.scheme?.lowercased() == "https" {
            coverURL = url
        } else {
            coverURL = nil
        }
    }

    func replacingCoverURL(_ coverURL: URL) -> ZLibraryBook {
        ZLibraryBook(
            id: id,
            hash: hash,
            title: title,
            author: author,
            year: year,
            language: language,
            fileExtension: fileExtension,
            fileSize: fileSize,
            coverURL: coverURL,
            rating: rating,
            isbn: isbn
        )
    }

    private init(
        id: String,
        hash: String,
        title: String,
        author: String,
        year: String,
        language: String,
        fileExtension: String,
        fileSize: String,
        coverURL: URL?,
        rating: String,
        isbn: String
    ) {
        self.id = id
        self.hash = hash
        self.title = title
        self.author = author
        self.year = year
        self.language = language
        self.fileExtension = fileExtension
        self.fileSize = fileSize
        self.coverURL = coverURL
        self.rating = rating
        self.isbn = isbn
    }
}

nonisolated struct ZLibrarySearchPage: Equatable, Sendable {
    let books: [ZLibraryBook]
    let totalCount: Int?
    let page: Int
}

nonisolated struct ZLibraryDownloadQuota: Equatable, Sendable {
    let dailyLimit: Int?
    let usedToday: Int?
    let remaining: Int?
}

nonisolated struct ZLibraryBookDetails: Equatable, Sendable {
    let publisher: String
    let isbn: String
    let pages: String
    let series: String
    let description: String
    let categories: [String]

    var hasAdditionalMetadata: Bool {
        !publisher.isEmpty || !isbn.isEmpty || !pages.isEmpty || !series.isEmpty
            || !description.isEmpty || !categories.isEmpty
    }
}

nonisolated enum ZLibraryClientError: LocalizedError, Equatable {
    case invalidBaseURL
    case insecureURL
    case invalidCredentials
    case invalidSession
    case invalidResponse
    case serverUnavailable
    case networkUnavailable
    case timedOut
    case rateLimited
    case server(String)
    case redirectedToDifferentHost
    case unsupportedFormat
    case invalidEPUB
    case downloadTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            String(localized: "Enter a valid Z-Library server address.")
        case .insecureURL:
            String(localized: "The Z-Library server and download links must use HTTPS.")
        case .invalidCredentials:
            String(localized: "The email or password was rejected.")
        case .invalidSession:
            String(localized: "Your Z-Library session has expired. Sign in again.")
        case .invalidResponse:
            String(localized: "Z-Library returned an unexpected response.")
        case .serverUnavailable:
            String(localized: "This Z-Library server is unavailable. Try another server address.")
        case .networkUnavailable:
            String(localized: "Check your internet connection and try again.")
        case .timedOut:
            String(localized: "The Z-Library request timed out. Try again.")
        case .rateLimited:
            String(localized: "Z-Library is receiving too many requests. Try again later.")
        case .server:
            String(localized: "Z-Library returned an error. Try again later.")
        case .redirectedToDifferentHost:
            String(localized: "The Z-Library server redirected to another host. Update the server address and sign in again.")
        case .unsupportedFormat:
            String(localized: "Niratan can only import EPUB books from Z-Library.")
        case .invalidEPUB:
            String(localized: "The downloaded file is not a valid EPUB.")
        case .downloadTooLarge:
            String(localized: "The EPUB is too large to download.")
        }
    }
}

enum ZLibrarySessionStorage {
    private static let account = "zLibrarySession"
    private static let service = DevelopmentDataIsolation.keychainName("moe.shishamo.hoshi.zlibrary")

    static func load() -> ZLibrarySession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            return nil
        }
        return try? JSONDecoder().decode(ZLibrarySession.self, from: data)
    }

    @discardableResult
    static func save(_ session: ZLibrarySession) -> Bool {
        guard let data = try? JSONEncoder().encode(session) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

actor ZLibraryClient {
    static let maximumDownloadSize: Int64 = 1_073_741_824

    private let baseURL: URL
    private let session: URLSession
    private var credentials: ZLibrarySession?

    init(baseURL: URL, credentials: ZLibrarySession? = nil, session: URLSession? = nil) throws {
        self.baseURL = try Self.normalizedBaseURL(baseURL)
        if let credentials, credentials.baseOrigin == self.baseURL.absoluteString {
            self.credentials = credentials
        }
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            self.session = URLSession(
                configuration: configuration,
                delegate: ZLibraryRedirectDelegate(allowedHost: self.baseURL.host),
                delegateQueue: nil
            )
        }
    }

    static func normalizedBaseURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else {
            if url.scheme?.lowercased() != "https" { throw ZLibraryClientError.insecureURL }
            throw ZLibraryClientError.invalidBaseURL
        }
        components.scheme = "https"
        components.host = host.lowercased()
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let normalized = components.url else { throw ZLibraryClientError.invalidBaseURL }
        return normalized
    }

    func login(email: String, password: String) async throws -> ZLibrarySession {
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEmail.isEmpty, !password.isEmpty else { throw ZLibraryClientError.invalidCredentials }

        var request = URLRequest(url: endpoint("eapi/user/login"))
        request.httpMethod = "POST"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formData([
            URLQueryItem(name: "email", value: trimmedEmail),
            URLQueryItem(name: "password", value: password)
        ])
        let data = try await send(request, isLogin: true)
        let response = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard response.success == 1,
              let user = response.user,
              !user.id.isEmpty,
              !user.userKey.isEmpty else {
            if let message = response.errorMessage, !message.isEmpty {
                throw ZLibraryClientError.server(message)
            }
            throw ZLibraryClientError.invalidCredentials
        }
        let credentials = ZLibrarySession(
            baseOrigin: baseURL.absoluteString,
            userID: user.id,
            userKey: user.userKey
        )
        self.credentials = credentials
        return credentials
    }

    func search(_ searchRequest: ZLibrarySearchRequest) async throws -> ZLibrarySearchPage {
        guard !searchRequest.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ZLibrarySearchPage(books: [], totalCount: 0, page: searchRequest.page)
        }
        var request = authenticatedRequest(url: endpoint("eapi/book/search"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formData(searchRequest.formItems)
        let data = try await send(request, allowsRetry: true)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        if let message = response.errorMessage, !message.isEmpty {
            throw ZLibraryClientError.server(message)
        }
        let combinedBooks = (response.exactMatch?.books ?? []) + (response.books ?? [])
        var seenBookKeys = Set<String>()
        let books = combinedBooks.filter { book in
            seenBookKeys.insert("\(book.id):\(book.hash)").inserted
        }
        return ZLibrarySearchPage(
            books: books,
            totalCount: response.pagination?.totalItems ?? response.exactBooksCount,
            page: searchRequest.page
        )
    }

    func downloadQuota() async throws -> ZLibraryDownloadQuota {
        let request = authenticatedRequest(url: endpoint("eapi/user/profile"))
        let data = try await send(request, allowsRetry: true)
        let response = try JSONDecoder().decode(ProfileResponse.self, from: data)
        if let message = response.errorMessage, !message.isEmpty {
            throw ZLibraryClientError.server(message)
        }
        guard let user = response.user else { throw ZLibraryClientError.invalidResponse }
        let limit = user.downloadsTodayLimit ?? user.downloadsLimit ?? user.dailyDownloadLimit
        let used = user.downloadsToday ?? user.dailyDownloadsCount
            ?? Self.difference(limit, user.downloadsTodayLeft)
        let remaining = user.downloadsTodayLeft ?? Self.difference(limit, used)
        return ZLibraryDownloadQuota(
            dailyLimit: limit,
            usedToday: used,
            remaining: remaining.map { max(0, $0) }
        )
    }

    func bookDetails(for book: ZLibraryBook) async throws -> ZLibraryBookDetails {
        let response = try await bookResponse(for: book)
        guard let details = response.details else { throw ZLibraryClientError.invalidResponse }
        return details
    }

    func refreshedBook(for book: ZLibraryBook) async throws -> ZLibraryBook {
        let response = try await bookResponse(for: book)
        guard let refreshedBook = response.book else { throw ZLibraryClientError.invalidResponse }
        return refreshedBook
    }

    private func bookResponse(for book: ZLibraryBook) async throws -> BookDetailsResponse {
        let request = authenticatedRequest(url: endpoint("eapi/book/\(book.id)/\(book.hash)"))
        let data = try await send(request, allowsRetry: true)
        let response = try JSONDecoder().decode(BookDetailsResponse.self, from: data)
        if let message = response.errorMessage, !message.isEmpty {
            throw ZLibraryClientError.server(message)
        }
        return response
    }

    func recentlyAdded(limit: Int = 20) async throws -> ZLibrarySearchPage {
        let request = authenticatedRequest(url: endpoint("eapi/book/recently"))
        let data = try await send(request, allowsRetry: true)
        let response = try JSONDecoder().decode(BookCollectionResponse.self, from: data)
        if let message = response.errorMessage, !message.isEmpty {
            throw ZLibraryClientError.server(message)
        }
        let books = Array(
            (response.books ?? [])
                .filter(\.isEPUB)
                .prefix(min(max(limit, 1), 50))
        )
        return ZLibrarySearchPage(books: books, totalCount: books.count, page: 1)
    }

    func downloadHistory(page: Int = 1, limit: Int = 20) async throws -> ZLibrarySearchPage {
        let safePage = max(page, 1)
        let safeLimit = min(max(limit, 1), 50)
        let url = endpoint("eapi/user/book/downloaded").appending(queryItems: [
            URLQueryItem(name: "page", value: String(safePage)),
            URLQueryItem(name: "limit", value: String(safeLimit))
        ])
        let request = authenticatedRequest(url: url)
        let data = try await send(request, allowsRetry: true)
        let response = try JSONDecoder().decode(BookCollectionResponse.self, from: data)
        if let message = response.errorMessage, !message.isEmpty {
            throw ZLibraryClientError.server(message)
        }
        return ZLibrarySearchPage(
            books: response.books ?? [],
            totalCount: response.pagination?.totalItems,
            page: safePage
        )
    }

    func downloadEPUB(
        _ book: ZLibraryBook,
        progress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) async throws -> URL {
        guard book.isEPUB else { throw ZLibraryClientError.unsupportedFormat }
        let linkRequest = authenticatedRequest(url: endpoint("eapi/book/\(book.id)/\(book.hash)/file"))
        let linkData = try await send(linkRequest, allowsRetry: true)
        let linkResponse = try JSONDecoder().decode(DownloadLinkResponse.self, from: linkData)
        guard let link = linkResponse.downloadLink,
              let downloadURL = URL(string: link, relativeTo: baseURL)?.absoluteURL else {
            if let message = linkResponse.errorMessage, !message.isEmpty {
                throw ZLibraryClientError.server(message)
            }
            throw ZLibraryClientError.invalidResponse
        }
        guard downloadURL.scheme?.lowercased() == "https" else { throw ZLibraryClientError.insecureURL }

        var request = URLRequest(url: downloadURL)
        request.setValue("application/epub+zip, application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(baseURL.absoluteString, forHTTPHeaderField: "Referer")
        if downloadURL.host?.caseInsensitiveCompare(baseURL.host ?? "") == .orderedSame {
            addAuthentication(to: &request)
        }
        let (temporaryURL, response): (URL, URLResponse)
        do {
            if session.delegate is ZLibraryRedirectDelegate {
                let delegate = ZLibraryDownloadDelegate(
                    allowedHost: baseURL.host,
                    maximumSize: Self.maximumDownloadSize,
                    progress: progress
                )
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpShouldSetCookies = false
                configuration.timeoutIntervalForRequest = 30
                configuration.timeoutIntervalForResource = 120
                let downloadSession = URLSession(
                    configuration: configuration,
                    delegate: delegate,
                    delegateQueue: nil
                )
                defer { downloadSession.finishTasksAndInvalidate() }
                (temporaryURL, response) = try await delegate.download(request, using: downloadSession)
            } else {
                progress(nil)
                (temporaryURL, response) = try await session.download(for: request)
            }
        } catch {
            throw Self.mapNetworkError(error)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        try validate(response)
        if response.expectedContentLength > Self.maximumDownloadSize {
            throw ZLibraryClientError.downloadTooLarge
        }
        let mimeType = response.mimeType?.lowercased() ?? ""
        guard !mimeType.contains("text/html"), !mimeType.contains("application/json") else {
            throw ZLibraryClientError.invalidResponse
        }
        let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0 else { throw ZLibraryClientError.invalidEPUB }
        guard Int64(size) <= Self.maximumDownloadSize else { throw ZLibraryClientError.downloadTooLarge }
        let handle = try FileHandle(forReadingFrom: temporaryURL)
        defer { try? handle.close() }
        let signature = try handle.read(upToCount: 4) ?? Data()
        guard signature.starts(with: [0x50, 0x4B]) else { throw ZLibraryClientError.invalidEPUB }

        let title = Self.safeFilename(book.title.isEmpty ? book.id : book.title)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(title)")
            .appendingPathExtension("epub")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func endpoint(_ path: String) -> URL {
        path.split(separator: "/").reduce(baseURL) { url, component in
            url.appendingPathComponent(String(component))
        }
    }

    private func authenticatedRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        addAuthentication(to: &request)
        return request
    }

    private func addAuthentication(to request: inout URLRequest) {
        guard let credentials else { return }
        request.setValue(
            "remix_userid=\(credentials.userID); remix_userkey=\(credentials.userKey); siteLanguageV2=en",
            forHTTPHeaderField: "Cookie"
        )
    }

    private func send(
        _ request: URLRequest,
        isLogin: Bool = false,
        allowsRetry: Bool = false
    ) async throws -> Data {
        let maximumAttempts = allowsRetry ? 3 : 1
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    if (300..<400).contains(http.statusCode) {
                        throw ZLibraryClientError.serverUnavailable
                    }
                    if isLogin, (400..<500).contains(http.statusCode) {
                        throw ZLibraryClientError.invalidCredentials
                    }
                    if http.statusCode == 401 || http.statusCode == 403 {
                        throw ZLibraryClientError.invalidSession
                    }
                    if http.statusCode == 429 {
                        throw ZLibraryClientError.rateLimited
                    }
                    if (500..<600).contains(http.statusCode) {
                        throw ZLibraryClientError.serverUnavailable
                    }
                    if let apiError = try? JSONDecoder().decode(ZLibraryAPIErrorEnvelope.self, from: data),
                       apiError.message.nilIfEmpty != nil {
                        throw ZLibraryClientError.server(apiError.message)
                    }
                }
                try validate(response)
                return data
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let mappedError = Self.mapNetworkError(error)
                attempt += 1
                guard attempt < maximumAttempts, Self.isRetryable(mappedError) else {
                    throw mappedError
                }
                try await Task.sleep(for: .milliseconds(400 * (1 << (attempt - 1))))
            }
        }
    }

    private static func mapNetworkError(_ error: Error) -> Error {
        guard let urlError = error as? URLError else { return error }
        switch urlError.code {
        case .cancelled:
            return CancellationError()
        case .timedOut:
            return ZLibraryClientError.timedOut
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed:
            return ZLibraryClientError.networkUnavailable
        case .httpTooManyRedirects:
            return ZLibraryClientError.serverUnavailable
        default:
            return error
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        guard let error = error as? ZLibraryClientError else { return false }
        switch error {
        case .serverUnavailable, .networkUnavailable, .timedOut:
            return true
        default:
            return false
        }
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ZLibraryClientError.invalidResponse }
        guard let finalURL = http.url,
              finalURL.scheme?.lowercased() == "https" else { throw ZLibraryClientError.insecureURL }
        guard (200..<300).contains(http.statusCode) else {
            if (300..<400).contains(http.statusCode) { throw ZLibraryClientError.serverUnavailable }
            if http.statusCode == 401 || http.statusCode == 403 { throw ZLibraryClientError.invalidSession }
            if http.statusCode == 429 { throw ZLibraryClientError.rateLimited }
            if (500..<600).contains(http.statusCode) { throw ZLibraryClientError.serverUnavailable }
            throw ZLibraryClientError.invalidResponse
        }
    }

    private static func formData(_ items: [URLQueryItem]) -> Data? {
        var components = URLComponents()
        components.queryItems = items
        return components.percentEncodedQuery?.data(using: .utf8)
    }

    private static func safeFilename(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)
        let sanitized = name.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((sanitized.isEmpty ? "Z-Library Book" : sanitized).prefix(120))
    }

    private static func difference(_ total: Int?, _ part: Int?) -> Int? {
        guard let total, let part else { return nil }
        return total - part
    }
}

private final class ZLibraryRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHost: String?

    init(allowedHost: String?) {
        self.allowedHost = allowedHost
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let sourceHost = response.url?.host
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.caseInsensitiveCompare(sourceHost ?? allowedHost ?? "") == .orderedSame else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private final class ZLibraryDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let allowedHost: String?
    private let maximumSize: Int64
    private let progressHandler: @Sendable (Double?) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var downloadedURL: URL?
    private var downloadError: Error?
    private var exceededSizeLimit = false

    init(
        allowedHost: String?,
        maximumSize: Int64,
        progress: @escaping @Sendable (Double?) -> Void
    ) {
        self.allowedHost = allowedHost
        self.maximumSize = maximumSize
        self.progressHandler = progress
    }

    func download(_ request: URLRequest, using session: URLSession) async throws -> (URL, URLResponse) {
        let reference = ZLibraryDownloadTaskReference()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.downloadTask(with: request)
                lock.withLock {
                    self.continuation = continuation
                }
                reference.set(task)
                progressHandler(nil)
                task.resume()
            }
        } onCancel: {
            reference.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        let sourceHost = response.url?.host
        guard request.url?.scheme?.lowercased() == "https",
              request.url?.host?.caseInsensitiveCompare(sourceHost ?? allowedHost ?? "") == .orderedSame else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten <= maximumSize else {
            lock.withLock { exceededSizeLimit = true }
            downloadTask.cancel()
            return
        }
        reportProgress(for: downloadTask)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("zlibrary-download-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: destination)
            lock.withLock { downloadedURL = destination }
        } catch {
            lock.withLock { downloadError = error }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let completion = lock.withLock { () -> CheckedContinuation<(URL, URLResponse), Error>? in
            defer { continuation = nil }
            return continuation
        }
        guard let completion else { return }
        if lock.withLock({ exceededSizeLimit }) {
            completion.resume(throwing: ZLibraryClientError.downloadTooLarge)
        } else if let downloadError = lock.withLock({ downloadError }) {
            completion.resume(throwing: downloadError)
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                completion.resume(throwing: CancellationError())
            } else {
                completion.resume(throwing: error)
            }
        } else if let downloadedURL = lock.withLock({ downloadedURL }), let response = task.response {
            progressHandler(1)
            completion.resume(returning: (downloadedURL, response))
        } else {
            completion.resume(throwing: ZLibraryClientError.invalidResponse)
        }
    }

    private func reportProgress(for task: URLSessionTask) {
        let received = task.countOfBytesReceived
        if received > maximumSize {
            lock.withLock { exceededSizeLimit = true }
            task.cancel()
            return
        }
        let expected = task.countOfBytesExpectedToReceive
        progressHandler(expected > 0 ? min(Double(received) / Double(expected), 1) : nil)
    }
}

nonisolated private final class ZLibraryDownloadTaskReference: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var isCancelled = false

    func set(_ task: URLSessionTask) {
        let shouldCancel = lock.withLock { () -> Bool in
            self.task = task
            return isCancelled
        }
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionTask? in
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }
}

nonisolated private struct LoginResponse: Decodable {
    let success: Int
    let user: LoginUser?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey { case success, user, error, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        success = container.lossyInt(forKey: .success) ?? 0
        user = try? container.decode(LoginUser.self, forKey: .user)
        errorMessage = container.errorMessage(forKey: .error)
            ?? container.lossyString(forKey: .message).nilIfEmpty
    }
}

nonisolated private struct LoginUser: Decodable {
    let id: String
    let userKey: String

    private enum CodingKeys: String, CodingKey { case id, userKey = "remix_userkey" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.lossyString(forKey: .id)
        userKey = container.lossyString(forKey: .userKey)
    }
}

nonisolated private struct SearchResponse: Decodable {
    let books: [ZLibraryBook]?
    let exactMatch: ExactMatch?
    let pagination: Pagination?
    let exactBooksCount: Int?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey {
        case books, exactMatch, pagination, exactBooksCount, error, message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        books = try? container.decode([ZLibraryBook].self, forKey: .books)
        exactMatch = try? container.decode(ExactMatch.self, forKey: .exactMatch)
        pagination = try? container.decode(Pagination.self, forKey: .pagination)
        exactBooksCount = container.lossyInt(forKey: .exactBooksCount)
        errorMessage = container.errorMessage(forKey: .error)
            ?? container.lossyString(forKey: .message).nilIfEmpty
    }
}

nonisolated private struct BookCollectionResponse: Decodable {
    let books: [ZLibraryBook]?
    let pagination: Pagination?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey { case books, pagination, error, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        books = try? container.decode([ZLibraryBook].self, forKey: .books)
        pagination = try? container.decode(Pagination.self, forKey: .pagination)
        errorMessage = container.errorMessage(forKey: .error)
            ?? container.lossyString(forKey: .message).nilIfEmpty
    }
}

nonisolated private struct ProfileResponse: Decodable {
    let user: ProfileUser?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey { case user, error, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        user = (try? container.decode(ProfileUser.self, forKey: .user))
            ?? (try? ProfileUser(from: decoder))
        errorMessage = container.errorMessage(forKey: .error)
            ?? container.lossyString(forKey: .message).nilIfEmpty
    }
}

nonisolated private struct ProfileUser: Decodable {
    let downloadsToday: Int?
    let downloadsLimit: Int?
    let dailyDownloadLimit: Int?
    let dailyDownloadsCount: Int?
    let downloadsTodayLimit: Int?
    let downloadsTodayLeft: Int?

    private enum CodingKeys: String, CodingKey {
        case downloadsToday = "downloads_today"
        case downloadsLimit = "downloads_limit"
        case dailyDownloadLimit
        case dailyDownloadsCount
        case downloadsTodayLimit = "downloads_today_limit"
        case downloadsTodayLeft = "downloads_today_left"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        downloadsToday = container.lossyInt(forKey: .downloadsToday)
        downloadsLimit = container.lossyInt(forKey: .downloadsLimit)
        dailyDownloadLimit = container.lossyInt(forKey: .dailyDownloadLimit)
        dailyDownloadsCount = container.lossyInt(forKey: .dailyDownloadsCount)
        downloadsTodayLimit = container.lossyInt(forKey: .downloadsTodayLimit)
        downloadsTodayLeft = container.lossyInt(forKey: .downloadsTodayLeft)
    }
}

nonisolated private struct BookDetailsResponse: Decodable {
    let book: ZLibraryBook?
    let details: ZLibraryBookDetails?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey { case book, error, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        book = try? container.decode(ZLibraryBook.self, forKey: .book)
        details = (try? container.decode(BookDetailsPayload.self, forKey: .book))?.details
            ?? (try? BookDetailsPayload(from: decoder).details)
        errorMessage = container.errorMessage(forKey: .error)
            ?? container.lossyString(forKey: .message).nilIfEmpty
    }
}

nonisolated private struct BookDetailsPayload: Decodable {
    let details: ZLibraryBookDetails

    private enum CodingKeys: String, CodingKey {
        case publisher, isbn, pages, series, description, categories
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let categories: [String]
        if let values = try? container.decode([String].self, forKey: .categories) {
            categories = values
        } else {
            let value = container.lossyString(forKey: .categories)
            categories = value.isEmpty ? [] : [value]
        }
        details = ZLibraryBookDetails(
            publisher: container.lossyString(forKey: .publisher),
            isbn: container.lossyString(forKey: .isbn),
            pages: container.lossyString(forKey: .pages),
            series: container.lossyString(forKey: .series),
            description: container.lossyString(forKey: .description)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines),
            categories: categories.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )
    }
}

nonisolated private struct ExactMatch: Decodable { let books: [ZLibraryBook] }

nonisolated private struct Pagination: Decodable {
    let totalItems: Int?
    private enum CodingKeys: String, CodingKey { case totalItems = "total_items" }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        totalItems = container.lossyInt(forKey: .totalItems)
    }
}

nonisolated private struct DownloadLinkResponse: Decodable {
    let downloadLink: String?
    let errorMessage: String?

    private enum CodingKeys: String, CodingKey { case file, downloadLink, url, link, error, message }
    private enum FileKeys: String, CodingKey { case downloadLink }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let nested = try? container.nestedContainer(keyedBy: FileKeys.self, forKey: .file)
        downloadLink = nested?.lossyString(forKey: .downloadLink).nilIfEmpty
            ?? container.lossyString(forKey: .downloadLink).nilIfEmpty
            ?? container.lossyString(forKey: .url).nilIfEmpty
            ?? container.lossyString(forKey: .link).nilIfEmpty
        errorMessage = container.errorMessage(forKey: .error)
            ?? container.lossyString(forKey: .message).nilIfEmpty
    }
}

nonisolated private extension KeyedDecodingContainer {
    func lossyString(forKey key: Key) -> String {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Int.self, forKey: key) { return String(value) }
        if let value = try? decode(Double.self, forKey: key) { return String(value) }
        return ""
    }

    func lossyInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Int(value) }
        return nil
    }

    func errorMessage(forKey key: Key) -> String? {
        (try? decode(ZLibraryAPIError.self, forKey: key))?.message.nilIfEmpty
    }
}

nonisolated private struct ZLibraryAPIError: Decodable {
    let message: String

    private enum CodingKeys: String, CodingKey { case message, error }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            message = value
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = container.lossyString(forKey: .message).nilIfEmpty
            ?? container.lossyString(forKey: .error)
    }
}

nonisolated private struct ZLibraryAPIErrorEnvelope: Decodable {
    let message: String

    private enum CodingKeys: String, CodingKey { case error, message }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = container.errorMessage(forKey: .error)
            ?? container.lossyString(forKey: .message)
    }
}

nonisolated private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
