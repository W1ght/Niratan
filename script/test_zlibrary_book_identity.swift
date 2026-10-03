// test-sources: Models/Book.swift
import Foundation

@main
private enum ZLibraryBookIdentityTests {
    static func main() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "title": "Legacy Book",
          "epub": "book.epub",
          "cover": null,
          "folder": "Legacy Book",
          "lastAccess": 0
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let legacy = try decoder.decode(BookMetadata.self, from: Data(legacyJSON.utf8))
        precondition(legacy.externalSourceID == nil)
        precondition(legacy.externalISBN == nil)

        let current = BookMetadata(
            title: "Current Book",
            cover: nil,
            folder: "Current Book",
            lastAccess: Date(timeIntervalSince1970: 0),
            externalSourceID: "zlibrary:123",
            externalISBN: "978-4-00-000000-0"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let roundTrip = try decoder.decode(BookMetadata.self, from: encoder.encode(current))
        precondition(roundTrip.externalSourceID == "zlibrary:123")
        precondition(roundTrip.externalISBN == "978-4-00-000000-0")
        print("Z-Library book identity tests passed")
    }
}
