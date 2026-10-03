// test-sources: Features/Reader/ReaderStatisticsPersistencePolicy.swift
import Foundation

@main
enum ReaderStatisticsPersistencePolicyTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        require(
            ReaderStatisticsPersistencePolicy.shouldPersist(
                modelChapterIndex: 17,
                modelCharacter: 80_791,
                persistedBookmark: nil
            ),
            "a new book without a persisted bookmark should allow its first statistics write"
        )

        require(
            ReaderStatisticsPersistencePolicy.shouldPersist(
                modelChapterIndex: 17,
                modelCharacter: 80_791,
                persistedBookmark: .init(chapterIndex: 17, characterCount: 80_791)
            ),
            "the model that owns the current persisted bookmark should write statistics"
        )

        require(
            !ReaderStatisticsPersistencePolicy.shouldPersist(
                modelChapterIndex: 17,
                modelCharacter: 80_273,
                persistedBookmark: .init(chapterIndex: 17, characterCount: 80_791)
            ),
            "a stale model behind the persisted bookmark must not overwrite newer statistics"
        )

        require(
            !ReaderStatisticsPersistencePolicy.shouldPersist(
                modelChapterIndex: 16,
                modelCharacter: 72_340,
                persistedBookmark: .init(chapterIndex: 17, characterCount: 72_340)
            ),
            "a stale chapter-boundary model must be rejected even when raw character positions match"
        )

        require(
            ReaderStatisticsPersistencePolicy.shouldPersist(
                modelChapterIndex: 17,
                modelCharacter: 79_736,
                persistedBookmark: .init(chapterIndex: 17, characterCount: 79_736)
            ),
            "an intentional backwards page turn should remain writable once its bookmark is persisted"
        )

        print("Reader statistics persistence policy tests passed")
    }
}
