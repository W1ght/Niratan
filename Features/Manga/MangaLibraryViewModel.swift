import Foundation
import Observation

nonisolated struct MangaShelfSection: Identifiable, Sendable {
    let shelf: MangaShelf?
    var items: [MangaLibraryItem]
    var isReading = false
    var isAll = false

    /// All and Reading mix items from several orders, so only real shelves and Unshelved reorder.
    var allowsReordering: Bool {
        !isReading && !isAll
    }

    var id: String {
        if isAll {
            return "__all__"
        }
        if isReading {
            return "__reading__"
        }
        return shelf.map { "shelf:\($0.id.uuidString)" } ?? "unshelved"
    }
}

@Observable
@MainActor
final class MangaLibraryViewModel {
    var catalog: MangaLibraryCatalog = .empty
    var hasLoadedCatalog = false
    var isScanning = false
    var shouldShowError = false
    var errorMessage = ""
    var shelfSelection: LibraryShelfSelection = .all
    var sortOption: MangaLibrarySortOption {
        didSet {
            MangaLibraryPreferences.save(sortOption: sortOption, in: preferences)
        }
    }
    var showReading: Bool {
        didSet {
            MangaLibraryPreferences.save(showReading: showReading, in: preferences)
        }
    }

    private let store: MangaLibraryStore
    private let preferences: UserDefaults
    private var scanTask: Task<Void, Never>?
    private var isLoadingCatalog = false

    init(
        store: MangaLibraryStore = .shared,
        preferences: UserDefaults = .standard
    ) {
        self.store = store
        self.preferences = preferences
        sortOption = MangaLibraryPreferences.sortOption(in: preferences)
        showReading = MangaLibraryPreferences.showReading(in: preferences)
    }

    var visibleItems: [MangaLibraryItem] {
        catalog.items.filter { !catalog.hiddenItemIDs.contains($0.id) }
    }

    func sections() -> [MangaShelfSection] {
        var sections: [MangaShelfSection] = []

        if showReading {
            let reading = visibleItems.filter {
                $0.lastReadAt != nil
                    && $0.progress < 0.999
            }
            if !reading.isEmpty {
                sections.append(
                    MangaShelfSection(
                        shelf: MangaShelf(name: "Reading"),
                        items: sort(reading, using: readingManualOrder),
                        isReading: true
                    )
                )
            }
        }

        for shelf in catalog.shelves {
            let shelfItems = visibleItems.filter {
                shelf.itemIDs.contains($0.id)
            }
            sections.append(
                MangaShelfSection(
                    shelf: shelf,
                    items: sort(shelfItems, using: shelf.itemIDs)
                )
            )
        }

        let shelvedIDs = Set(catalog.shelves.flatMap(\.itemIDs))
        let unshelved = visibleItems.filter {
            !shelvedIDs.contains($0.id)
        }
        sections.append(
            MangaShelfSection(
                shelf: nil,
                items: sort(unshelved, using: catalog.manualItemOrder)
            )
        )
        return sections
    }

    /// The shelf column selection, falling back to All when its shelf no longer exists.
    var resolvedShelfSelection: LibraryShelfSelection {
        switch shelfSelection {
        case .shelf(let key) where !catalog.shelves.contains(where: { $0.id.uuidString == key }):
            return .all
        case .googleDrive:
            return .all
        default:
            return shelfSelection
        }
    }

    func section(for selection: LibraryShelfSelection) -> MangaShelfSection {
        switch selection {
        case .all, .googleDrive:
            return MangaShelfSection(
                shelf: nil,
                items: sort(visibleItems, using: readingManualOrder),
                isAll: true
            )
        case .reading:
            return MangaShelfSection(
                shelf: nil,
                items: sort(readingItems, using: readingManualOrder),
                isReading: true
            )
        case .unshelved:
            return MangaShelfSection(
                shelf: nil,
                items: sort(unshelvedItems, using: catalog.manualItemOrder)
            )
        case .shelf(let key):
            guard let shelf = catalog.shelves.first(where: { $0.id.uuidString == key }) else {
                return section(for: .all)
            }
            return MangaShelfSection(
                shelf: shelf,
                items: sort(
                    visibleItems.filter { shelf.itemIDs.contains($0.id) },
                    using: shelf.itemIDs
                )
            )
        }
    }

    func itemCount(for selection: LibraryShelfSelection) -> Int {
        switch selection {
        case .all, .googleDrive:
            return visibleItems.count
        case .reading:
            return readingItems.count
        case .unshelved:
            return unshelvedItems.count
        case .shelf(let key):
            guard let shelf = catalog.shelves.first(where: { $0.id.uuidString == key }) else {
                return 0
            }
            let shelfIDs = Set(shelf.itemIDs)
            return visibleItems.filter { shelfIDs.contains($0.id) }.count
        }
    }

    func shelfID(containing itemID: String) -> UUID? {
        catalog.shelves.first { $0.itemIDs.contains(itemID) }?.id
    }

    private var readingItems: [MangaLibraryItem] {
        visibleItems.filter {
            $0.lastReadAt != nil
                && $0.progress < 0.999
        }
    }

    private var unshelvedItems: [MangaLibraryItem] {
        let shelvedIDs = Set(catalog.shelves.flatMap(\.itemIDs))
        return visibleItems.filter { !shelvedIDs.contains($0.id) }
    }

    func load() {
        guard !isLoadingCatalog else { return }
        isLoadingCatalog = true
        Task {
            defer {
                isLoadingCatalog = false
                hasLoadedCatalog = true
            }
            catalog = await store.snapshot()
            await store.splitMergedMokuroSourcesIfNeeded()
            catalog = await store.snapshot()
        }
    }

    func addSources(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        runScan {
            for url in urls {
                try Task.checkCancellation()
                let source = try await self.store.addSource(url: url)
                try await self.store.scanSource(id: source.id)
                self.catalog = await self.store.snapshot()
            }
        }
    }

    func removeSource(id: UUID) {
        perform {
            await self.store.removeSource(id: id)
        }
    }

    func source(for item: MangaLibraryItem) -> MangaLibrarySource? {
        catalog.sources.first { $0.id == item.sourceID }
    }

    /// Creates a shelf and returns its key. The shelf is shown right away so it can be renamed inline.
    @discardableResult
    func createShelf(name: String) -> String? {
        guard let name = LibraryShelfNaming.normalized(name),
              LibraryShelfNaming.isAvailable(name, among: catalog.shelves.map(\.name)) else {
            return nil
        }
        let shelf = MangaShelf(name: name)
        catalog.shelves.append(shelf)
        perform {
            await self.store.createShelf(name: name, id: shelf.id)
        }
        return shelf.id.uuidString
    }

    /// Renames a shelf in place, keeping its items and position. Manga shelf keys never change.
    @discardableResult
    func renameShelf(id: UUID, to newName: String) -> String? {
        guard let index = catalog.shelves.firstIndex(where: { $0.id == id }),
              let name = LibraryShelfNaming.normalized(newName),
              LibraryShelfNaming.isAvailable(
                  name,
                  among: catalog.shelves.map(\.name),
                  excluding: catalog.shelves[index].name
              ) else {
            return nil
        }
        catalog.shelves[index].name = name
        perform {
            await self.store.renameShelf(id: id, name: name)
        }
        return id.uuidString
    }

    func deleteShelf(id: UUID) {
        catalog.shelves.removeAll { $0.id == id }
        perform {
            await self.store.deleteShelf(id: id)
        }
    }

    func moveShelves(from source: IndexSet, to destination: Int) {
        let movedShelves = source.map { catalog.shelves[$0] }
        let insertionIndex = destination - source.count(in: 0..<destination)
        for index in source.reversed() {
            catalog.shelves.remove(at: index)
        }
        catalog.shelves.insert(contentsOf: movedShelves, at: insertionIndex)
        perform {
            await self.store.moveShelves(from: source, to: destination)
        }
    }

    func moveItems(_ items: Set<MangaLibraryItem>, to shelfID: UUID?) {
        moveItemIDs(Set(items.map(\.id)), to: shelfID)
    }

    func moveItem(_ item: MangaLibraryItem, to shelfID: UUID?) {
        moveItemIDs([item.id], to: shelfID)
    }

    func reorderItem(
        _ sourceID: String,
        in section: MangaShelfSection,
        before targetID: String
    ) {
        guard section.allowsReordering else { return }
        sortOption = .manual
        perform {
            await self.store.reorderItem(
                sourceID,
                shelfID: section.shelf?.id,
                before: targetID
            )
        }
    }

    func renameItem(_ item: MangaLibraryItem, title: String) {
        perform {
            await self.store.renameItem(id: item.id, title: title)
        }
    }

    func markRead(_ item: MangaLibraryItem) {
        perform {
            await self.store.markRead(itemID: item.id)
        }
    }

    func recordOpened(_ item: MangaLibraryItem) {
        perform {
            await self.store.recordOpened(itemID: item.id)
        }
    }

    func removeItemsFromLibrary(_ items: Set<MangaLibraryItem>) {
        let ids = Set(items.map(\.id))
        perform {
            await self.store.removeItemsFromLibrary(ids)
        }
    }

    func cancelScanning() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }

    private var readingManualOrder: [String] {
        catalog.shelves.flatMap(\.itemIDs) + catalog.manualItemOrder
    }

    private func sort(
        _ items: [MangaLibraryItem],
        using manualOrder: [String]
    ) -> [MangaLibraryItem] {
        switch sortOption {
        case .manual:
            let positions = Dictionary(
                uniqueKeysWithValues: manualOrder.enumerated().map { ($1, $0) }
            )
            return items.sorted {
                switch (positions[$0.id], positions[$1.id]) {
                case let (left?, right?):
                    return left < right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    return $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
                }
            }
        case .recent:
            return items.sorted {
                ($0.lastReadAt ?? .distantPast) > ($1.lastReadAt ?? .distantPast)
            }
        case .title:
            return items.sorted {
                $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending
            }
        }
    }

    private func moveItemIDs(_ ids: Set<String>, to shelfID: UUID?) {
        guard !ids.isEmpty else { return }
        perform {
            await self.store.moveItems(ids, to: shelfID)
        }
    }

    private func perform(
        _ operation: @escaping @MainActor () async -> Void
    ) {
        Task {
            await operation()
            catalog = await store.snapshot()
        }
    }

    private func runScan(
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        scanTask?.cancel()
        isScanning = true
        scanTask = Task {
            defer {
                isScanning = false
                scanTask = nil
            }
            do {
                try await operation()
                catalog = await store.snapshot()
            } catch is CancellationError {
                catalog = await store.snapshot()
            } catch {
                catalog = await store.snapshot()
                errorMessage = error.localizedDescription
                shouldShowError = true
            }
        }
    }
}
