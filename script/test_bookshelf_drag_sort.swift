// test-sources: Models/Book.swift
import Foundation

@main
private enum BookshelfDragSortTests {
    static func main() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000123")!
        let payload = BookReorder.payload(for: id)

        expect(payload == "hoshi-book:\(id.uuidString)", "book drag payload should be scoped")
        expect(BookReorder.bookID(from: payload) == id, "book drag payload should decode the book id")
        expect(BookReorder.bookID(from: id.uuidString) == nil, "unscoped UUID text should not reorder books")
        expect(BookReorder.bookID(from: "hoshi-book:") == nil, "empty book drag payload should be ignored")
        expect(BookReorder.destinationOffset(sourceIndex: 0, targetIndex: 2) == 3, "downward drops should account for Swift Array.move insertion semantics")
        expect(BookReorder.destinationOffset(sourceIndex: 2, targetIndex: 0) == 0, "upward drops should insert at the target index")
        expect(BookReorder.destinationOffset(sourceIndex: 1, targetIndex: 1) == nil, "same-card drops should not persist a redundant reorder")

        print("Bookshelf drag sort tests passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
