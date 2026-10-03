//
//  ReaderPageIndex.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import Foundation

/// Book-wide page table measured from the paginated Reader layout. Each page is
/// identified by the global character offset it starts at.
nonisolated struct ReaderPageIndex: Equatable, Sendable {
    struct Progress: Equatable, Sendable {
        let page: Int
        let total: Int
        let chapterPage: Int
        let chapterTotal: Int
    }

    private(set) var pageStarts: [Int] = []
    private(set) var spineFirstPages: [Int] = []

    /// - Parameters:
    ///   - spinePageStarts: per spine item, the spine-local character offset of each page.
    ///   - spineStartCharacters: the global character offset of each spine item.
    init(spinePageStarts: [[Int]], spineStartCharacters: [Int]) {
        for (spineIndex, starts) in spinePageStarts.enumerated() {
            spineFirstPages.append(pageStarts.count)
            let spineStart = spineStartCharacters.indices.contains(spineIndex) ? spineStartCharacters[spineIndex] : 0
            pageStarts += starts.map { spineStart + $0 }
        }
    }

    var isEmpty: Bool { pageStarts.isEmpty }
    var totalPages: Int { pageStarts.count }

    /// Zero-based global page containing `character` inside `spineIndex`.
    func page(at character: Int, spineIndex: Int) -> Int? {
        guard spineFirstPages.indices.contains(spineIndex) else { return nil }
        let firstPage = spineFirstPages[spineIndex]
        let endPage = spineIndex + 1 < spineFirstPages.count ? spineFirstPages[spineIndex + 1] : pageStarts.count
        guard firstPage < endPage else { return firstPage < pageStarts.count ? firstPage : nil }
        return (firstPage..<endPage).last { pageStarts[$0] <= character } ?? firstPage
    }

    /// Zero-based global page of a page index local to `spineIndex`.
    func page(spineIndex: Int, localPage: Int) -> Int? {
        guard spineFirstPages.indices.contains(spineIndex) else { return nil }
        let firstPage = spineFirstPages[spineIndex]
        let endPage = spineIndex + 1 < spineFirstPages.count ? spineFirstPages[spineIndex + 1] : pageStarts.count
        guard firstPage < endPage else { return nil }
        return min(max(firstPage + localPage, firstPage), endPage - 1)
    }

    func progress(
        page: Int,
        chapterStart: Int,
        chapterCount: Int,
        bookCharacterCount: Int
    ) -> Progress? {
        guard !pageStarts.isEmpty else { return nil }
        let page = min(max(page, 0), pageStarts.count - 1)
        let chapterEnd = chapterStart + chapterCount
        let chapterFirstPage = pageStarts.firstIndex(of: chapterStart)
            ?? pageStarts.lastIndex { $0 < chapterStart }
            ?? 0
        let chapterLastPage = chapterEnd >= bookCharacterCount
            ? pageStarts.count - 1
            : max(pageStarts.lastIndex { $0 < chapterEnd } ?? chapterFirstPage, chapterFirstPage)
        let chapterTotal = chapterLastPage - chapterFirstPage + 1
        let chapterPage = min(max(page - chapterFirstPage + 1, 1), chapterTotal)
        return Progress(page: page + 1, total: pageStarts.count, chapterPage: chapterPage, chapterTotal: chapterTotal)
    }
}
