//
//  GalleryView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

struct ReaderGalleryImage: Identifiable, Equatable {
    let url: URL
    let isRead: Bool
    /// Spine index of the chapter containing the image, for grouping.
    var chapterIndex: Int = -1
    var chapterTitle: String = ""

    var id: URL { url }
}

struct GalleryView: View {
    let images: [ReaderGalleryImage]
    let isLoading: Bool
    let backgroundColor: Color
    let onDismiss: () -> Void

    @State private var selectedImageIndex: Int?
    @State private var revealedImageIDs: Set<URL> = []

    private let columns = [
        GridItem(.adaptive(minimum: 250, maximum: 380), spacing: 16, alignment: .top)
    ]

    private struct ChapterSection: Identifiable {
        let id: Int
        let title: String
        let items: [(index: Int, image: ReaderGalleryImage)]
    }

    /// Images keep their book order; each run of images from one chapter
    /// becomes a section divided from the next.
    private var chapterSections: [ChapterSection] {
        var sections: [ChapterSection] = []
        for (index, image) in images.enumerated() {
            if let last = sections.last, last.id == image.chapterIndex {
                sections[sections.count - 1] = ChapterSection(
                    id: last.id,
                    title: last.title,
                    items: last.items + [(index, image)]
                )
            } else {
                sections.append(ChapterSection(id: image.chapterIndex, title: image.chapterTitle, items: [(index, image)]))
            }
        }
        return sections
    }

    private var imageCountText: String? {
        images.isEmpty ? nil : String.localizedStringWithFormat(String(localized: "%d images"), images.count)
    }

    private func sectionHeader(_ section: ChapterSection) -> some View {
        HStack(spacing: 10) {
            Text(section.title.isEmpty ? String(localized: "Untitled Chapter") : section.title)
                .font(.headline)
                .lineLimit(1)
            Text("\(section.items.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.07), in: Capsule())
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
        }
        .padding(.vertical, 8)
        .background(backgroundColor)
    }

    private func thumbnail(_ item: ReaderGalleryImage, index: Int) -> some View {
        let isBlurred = !item.isRead && !revealedImageIDs.contains(item.id)
        return Button {
            selectedImageIndex = index
        } label: {
            CoverImage(url: item.url, maxPixelSize: 1600) { image in
                image
                    .resizable()
                    .scaledToFit()
                    .blur(radius: isBlurred ? 18 : 0)
            } placeholder: {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.secondary.opacity(0.1))
                    .aspectRatio(0.7, contentMode: .fit)
            }
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 360)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if isBlurred {
                    Image(systemName: "eye.slash.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.black.opacity(0.45), in: Circle())
                }
            }
            .shadow(color: .black.opacity(0.14), radius: 8, y: 3)
        }
        .buttonStyle(GalleryThumbnailButtonStyle())
        .accessibilityLabel(
            isBlurred
                ? Text("Unread Image")
                : Text(verbatim: item.url.lastPathComponent)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            NativeReaderInspectorHeader(title: "Gallery", subtitle: imageCountText, onClose: onDismiss)
                .padding(.horizontal, 12)
                .padding(.top, 20)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18, pinnedViews: [.sectionHeaders]) {
                    ForEach(chapterSections) { section in
                        Section {
                            LazyVGrid(columns: columns, alignment: .center, spacing: 16) {
                                ForEach(section.items, id: \.image.id) { entry in
                                    thumbnail(entry.image, index: entry.index)
                                }
                            }
                        } header: {
                            sectionHeader(section)
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
            }
            .overlay {
                if isLoading {
                    ProgressView()
                        .controlSize(.large)
                } else if images.isEmpty {
                    ContentUnavailableView("No Images", systemImage: "photo.on.rectangle")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor.ignoresSafeArea())
        .onExitCommand {
            if selectedImageIndex == nil {
                onDismiss()
            }
        }
        .overlay {
            if selectedImageIndex != nil {
                GalleryImagePreview(
                    images: images,
                    selectedImageIndex: $selectedImageIndex,
                    revealedImageIDs: $revealedImageIDs,
                    backgroundColor: backgroundColor
                )
                .transition(.opacity)
                .zIndex(1)
            }
        }
    }
}

private struct GalleryImagePreview: View {
    let images: [ReaderGalleryImage]
    @Binding var selectedImageIndex: Int?
    @Binding var revealedImageIDs: Set<URL>
    let backgroundColor: Color

    private var currentIndex: Int? {
        guard let selectedImageIndex,
              images.indices.contains(selectedImageIndex) else {
            return nil
        }
        return selectedImageIndex
    }

    var body: some View {
        Group {
            if let currentIndex {
                NativeFullscreenImageView(
                    url: images[currentIndex].url,
                    backgroundColor: backgroundColor,
                    isBlurred: !images[currentIndex].isRead
                        && !revealedImageIDs.contains(images[currentIndex].id),
                    onReveal: {
                        revealedImageIDs.insert(images[currentIndex].id)
                    },
                    onDismiss: dismiss
                )
                .overlay {
                    HStack {
                        navigationButton(
                            systemName: "chevron.left",
                            label: "Previous",
                            key: .leftArrow,
                            isEnabled: currentIndex > images.startIndex,
                            action: showPrevious
                        )

                        Spacer()

                        navigationButton(
                            systemName: "chevron.right",
                            label: "Next",
                            key: .rightArrow,
                            isEnabled: currentIndex < images.index(before: images.endIndex),
                            action: showNext
                        )
                    }
                    .padding(.horizontal, 32)
                }
            } else {
                Color.clear
                    .onAppear(perform: dismiss)
            }
        }
        .onExitCommand(perform: dismiss)
    }

    private func navigationButton(
        systemName: String,
        label: LocalizedStringKey,
        key: KeyEquivalent,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        NativeGlassCircleButton(systemName: systemName, diameter: 44, fontSize: 17, action: action)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.35)
            .keyboardShortcut(key, modifiers: [])
            .accessibilityLabel(Text(label))
            .help(Text(label))
    }

    private func showPrevious() {
        guard let currentIndex, currentIndex > images.startIndex else { return }
        showImage(at: images.index(before: currentIndex))
    }

    private func showNext() {
        guard let currentIndex, currentIndex < images.index(before: images.endIndex) else { return }
        showImage(at: images.index(after: currentIndex))
    }

    private func showImage(at index: Int) {
        selectedImageIndex = index
    }

    private func dismiss() {
        selectedImageIndex = nil
    }
}

private struct GalleryThumbnailButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GalleryThumbnailHover(label: configuration.label, isPressed: configuration.isPressed)
    }
}

private struct GalleryThumbnailHover<Label: View>: View {
    let label: Label
    let isPressed: Bool
    @State private var isHovered = false

    var body: some View {
        label
            .scaleEffect(isPressed ? 0.98 : (isHovered ? 1.02 : 1))
            .animation(.snappy(duration: 0.16), value: isHovered)
            .animation(.snappy(duration: 0.12), value: isPressed)
            .onHover { isHovered = $0 }
    }
}
