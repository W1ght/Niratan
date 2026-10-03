import Foundation
import Observation

struct ReaderWindowOpenRequest: Identifiable, Equatable {
    let id: UUID
    let book: BookMetadata

    init(id: UUID = UUID(), book: BookMetadata) {
        self.id = id
        self.book = book
    }
}

@Observable
@MainActor
final class ReaderWindowCoordinator {
    static let windowID = "reader"
    static let closeRequestIDUserInfoKey = "requestID"

    private(set) var pendingRequest: ReaderWindowOpenRequest?
    private(set) var currentRequest: ReaderWindowOpenRequest?
    @ObservationIgnored private(set) var currentModel: NativeReaderModel?
    private(set) var sessionID = UUID()
    private(set) var isWindowPresented = false

    var currentBook: BookMetadata? {
        currentRequest?.book
    }

    @discardableResult
    func requestOpen(_ book: BookMetadata) -> ReaderWindowOpenRequest {
        if isWindowPresented,
           let currentRequest,
           currentRequest.book == book {
            return currentRequest
        }
        if !isWindowPresented || currentBook != book {
            sessionID = UUID()
        }
        let request = ReaderWindowOpenRequest(book: book)
        let model = NativeReaderModel(book: book)
        currentModel = model
        SyncReaderBridge.model = model
        pendingRequest = request
        currentRequest = request
        return request
    }

    func consume(_ requestID: UUID) {
        guard pendingRequest?.id == requestID else { return }
        pendingRequest = nil
    }

    func windowDidAppear() {
        isWindowPresented = true
    }

    func windowDidDisappear() {
        isWindowPresented = false
        currentModel = nil
        SyncReaderBridge.model = nil
        pendingRequest = nil
        currentRequest = nil
    }
}

extension Notification.Name {
    static let readerWindowWillClose = Notification.Name("ReaderWindowWillClose")
    static let readerWindowProgressDidChange = Notification.Name("ReaderWindowProgressDidChange")
}
