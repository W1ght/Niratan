import AppKit
import CoreImage
import QuartzCore
import UniformTypeIdentifiers

/// Visual and input configuration shared by the paged and continuous
/// canvases. Derived from `MangaReaderSettings` by the SwiftUI layer.
struct MangaCanvasStyle: Equatable {
    var settings: MangaReaderSettings
    var backgroundColor: NSColor
    var isPopupOpen: Bool

    var zoomScale: Double {
        Double(settings.zoomPercentage) / 100
    }

    var minimumZoomScale: Double {
        Double(settings.minimumEffectiveZoomPercentage) / 100
    }

    var maximumZoomScale: Double {
        Double(MangaReaderSettings.maximumZoomPercentage) / 100
    }

    var zoomSensitivity: Double {
        Double(settings.zoomSensitivity) / 100
    }

    func wheelZoomScale(
        from currentScale: Double,
        event: NSEvent
    ) -> Double? {
        MangaWheelZoomResolver.scale(
            currentScale: currentScale,
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas,
            minimumScale: minimumZoomScale,
            maximumScale: maximumZoomScale,
            sensitivityMultiplier: zoomSensitivity
        )
    }

    /// Core Image filters equivalent to Fushi's CSS page filter.
    var imageFilters: [CIFilter] {
        var filters: [CIFilter] = []
        let saturation = settings.effectiveGrayscale ? 0 : Double(settings.saturation) / 100
        let contrast = Double(settings.contrast) / 100
        if saturation != 1 || contrast != 1,
           let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(saturation, forKey: kCIInputSaturationKey)
            controls.setValue(contrast, forKey: kCIInputContrastKey)
            controls.setValue(0, forKey: kCIInputBrightnessKey)
            filters.append(controls)
        }
        if settings.brightness != 0,
           let matrix = CIFilter(name: "CIColorMatrix") {
            // CSS brightness() multiplies each channel.
            let factor = CGFloat(1 + Double(settings.brightness) / 100)
            matrix.setValue(CIVector(x: factor, y: 0, z: 0, w: 0), forKey: "inputRVector")
            matrix.setValue(CIVector(x: 0, y: factor, z: 0, w: 0), forKey: "inputGVector")
            matrix.setValue(CIVector(x: 0, y: 0, z: factor, w: 0), forKey: "inputBVector")
            filters.append(matrix)
        }
        if settings.invertsColors,
           let invert = CIFilter(name: "CIColorInvert") {
            filters.append(invert)
        }
        return filters
    }

    static func == (lhs: MangaCanvasStyle, rhs: MangaCanvasStyle) -> Bool {
        lhs.settings == rhs.settings
            && lhs.backgroundColor == rhs.backgroundColor
            && lhs.isPopupOpen == rhs.isPopupOpen
    }
}

/// Callbacks from the canvas into the reader model.
struct MangaCanvasActions {
    var onSetCover: ((Int) -> Void)?
    var onZoomScaleChange: (Double) -> Void = { _ in }
    var onWheelTurn: (MangaPageTurn) -> Void = { _ in }
    var onTapZone: (MangaTapZoneAction) -> Void = { _ in }
    var onSwipeTurn: (MangaPageTurn) -> Void = { _ in }
    var onDismissOCRSelection: () -> Void = {}
    var onOCRSelection: (MangaOCRTextRegion, CGRect) -> Int? = { _, _ in nil }
    var onPreviousPage: () -> Void = {}
    var onNextPage: () -> Void = {}
    var onJumpToPage: () -> Void = {}
    var onToggleDirection: () -> Void = {}
    var onZoomStep: (Int) -> Void = { _ in }
}

@MainActor
protocol MangaCanvasInteractionHost: AnyObject {
    /// A left click or drag that did not hit OCR text.
    func canvasBlankMouseDown(_ event: NSEvent, in view: NSView)
}

// MARK: - Paged canvas

final class MangaZoomScrollView: NSScrollView, MangaCanvasInteractionHost {
    private static let wheelNavigationCooldown: TimeInterval = 0.25
    private static let swipeDistance: CGFloat = 72

    private let spreadView = MangaSpreadDocumentView()
    private var wheelNavigationAccumulator = MangaWheelNavigationAccumulator()
    private var representedImages: [NSImage] = []
    private var lastViewportSize: NSSize = .zero
    private var lastAppliedFitMagnification: CGFloat?
    private var lastWheelNavigationTime: TimeInterval = -.infinity
    private var isUpdatingFit = false
    private var requestedZoomScale: CGFloat = 1
    private var style: MangaCanvasStyle?
    private var actions = MangaCanvasActions()
    private var lastTurnToken = 0
    private var lastCommandID: UUID?
    private var pendingMenuToggle: DispatchWorkItem?
    private var isVerticalPaging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let centeredClipView = MangaCenteredClipView()
        centeredClipView.interactionHost = self
        contentView = centeredClipView
        wantsLayer = true
        drawsBackground = true
        backgroundColor = .black
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        allowsMagnification = true
        minMagnification = 0.1
        maxMagnification = 8
        spreadView.interactionHost = self
        documentView = spreadView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        guard !representedImages.isEmpty, !isUpdatingFit else { return }
        let viewportSize = contentSize
        guard viewportSize.width > 0, viewportSize.height > 0,
              viewportSize != lastViewportSize else {
            return
        }
        let shouldFollowFit = lastAppliedFitMagnification.map {
            abs(magnification - $0) < 0.002
        } ?? true
        lastViewportSize = viewportSize
        updateFitMagnification(apply: shouldFollowFit)
    }

    override func scrollWheel(with event: NSEvent) {
        let zoomModifiers: NSEvent.ModifierFlags = [.command, .control]
        if !event.modifierFlags.intersection(zoomModifiers).isEmpty,
           event.modifierFlags.intersection([.option, .shift]).isEmpty,
           handleModifierWheelZoom(event) {
            return
        }

        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard event.modifierFlags.intersection(disallowedModifiers).isEmpty else {
            wheelNavigationAccumulator.reset()
            super.scrollWheel(with: event)
            return
        }
        guard !event.hasPreciseScrollingDeltas else {
            wheelNavigationAccumulator.reset()
            super.scrollWheel(with: event)
            return
        }
        guard let navigation = MangaWheelNavigationResolver.navigation(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: false
        ) else {
            wheelNavigationAccumulator.reset()
            super.scrollWheel(with: event)
            return
        }
        // Fushi pans an enlarged page first and only turns once the page edge
        // is reached.
        if canScroll(toward: navigation) {
            wheelNavigationAccumulator.reset()
            super.scrollWheel(with: event)
            return
        }
        guard event.timestamp - lastWheelNavigationTime >= Self.wheelNavigationCooldown else {
            wheelNavigationAccumulator.reset()
            return
        }
        guard let resolved = wheelNavigationAccumulator.consume(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
        ) else {
            return
        }

        lastWheelNavigationTime = event.timestamp
        actions.onDismissOCRSelection()
        actions.onWheelTurn(resolved == .forward ? .forward : .backward)
    }

    // swiftlint:disable:next function_parameter_count
    func setContent(
        images: [NSImage],
        pageIndices: [Int],
        sourcePageIndices: [Int],
        ocrRegions: [Int: [MangaOCRTextRegion]],
        showsOCRSelection: Bool,
        style: MangaCanvasStyle,
        actions: MangaCanvasActions,
        turn: MangaPageTurn?,
        turnToken: Int,
        entryEdge: MangaPageEntryEdge,
        verticalPaging: Bool,
        command: MangaCanvasCommand?
    ) {
        let previousStyle = self.style
        self.style = style
        self.actions = actions
        isVerticalPaging = verticalPaging
        backgroundColor = style.backgroundColor
        let nextZoomScale = CGFloat(style.zoomScale)
        let zoomChanged = abs(requestedZoomScale - nextZoomScale) > 0.001
        let fitChanged = previousStyle?.settings.scaleType != style.settings.scaleType
        requestedZoomScale = nextZoomScale
        spreadView.onSetCover = actions.onSetCover
        spreadView.actions = actions
        spreadView.applyStyle(style)
        spreadView.setOCRRegions(
            ocrRegions,
            pageIndices: pageIndices,
            showsSelection: showsOCRSelection,
            onDismissSelection: actions.onDismissOCRSelection,
            onSelection: { [weak self] region, documentRect in
                guard let self else { return nil }
                return actions.onOCRSelection(region, self.topLeadingRect(documentRect))
            }
        )
        let imagesChanged = !images.isEmpty
            && (representedImages.count != images.count
                || !zip(representedImages, images).allSatisfy({ $0.0 === $0.1 }))
        if imagesChanged {
            wheelNavigationAccumulator.reset()
            if turnToken != lastTurnToken, let turn, !representedImages.isEmpty {
                addPageTransition(turn: turn, animation: style.settings.effectivePageAnimation)
            }
            representedImages = images
            spreadView.setImages(
                images,
                pageIndices: pageIndices,
                sourcePageIndices: sourcePageIndices
            )
        }
        lastTurnToken = turnToken
        if imagesChanged || zoomChanged || fitChanged {
            layoutSubtreeIfNeeded()
            lastViewportSize = contentSize
            updateFitMagnification(apply: true)
            if imagesChanged {
                scrollToEntryEdge(entryEdge)
            }
        }
        if let command, command.id != lastCommandID {
            lastCommandID = command.id
            perform(command)
        }
    }

    // MARK: Interaction

    func canvasBlankMouseDown(_ event: NSEvent, in view: NSView) {
        guard let window = event.window, let style else { return }
        let initialLocation = event.locationInWindow
        var previousLocation = initialLocation
        var isDragging = false
        let canPan = documentExceedsViewport
        while let nextEvent = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            switch nextEvent.type {
            case .leftMouseDragged:
                let location = nextEvent.locationInWindow
                if !isDragging,
                   hypot(location.x - initialLocation.x, location.y - initialLocation.y) >= 4 {
                    isDragging = true
                    if canPan {
                        NSCursor.closedHand.push()
                    }
                    actions.onDismissOCRSelection()
                }
                if isDragging, canPan {
                    pan(windowDelta: CGPoint(
                        x: location.x - previousLocation.x,
                        y: location.y - previousLocation.y
                    ))
                }
                previousLocation = location
            case .leftMouseUp:
                if isDragging {
                    if canPan {
                        NSCursor.pop()
                    } else {
                        handleSwipe(
                            deltaX: nextEvent.locationInWindow.x - initialLocation.x,
                            deltaY: nextEvent.locationInWindow.y - initialLocation.y
                        )
                    }
                } else {
                    handleClick(event, style: style)
                }
                return
            default:
                continue
            }
        }
    }

    private func handleSwipe(deltaX: CGFloat, deltaY: CGFloat) {
        guard let style else { return }
        if isVerticalPaging {
            guard abs(deltaY) >= Self.swipeDistance, abs(deltaY) > abs(deltaX) else { return }
            // Window coordinates grow upward: dragging up shows the next page.
            actions.onSwipeTurn(deltaY > 0 ? .forward : .backward)
            return
        }
        guard abs(deltaX) >= Self.swipeDistance, abs(deltaX) > abs(deltaY) else { return }
        let draggedRight = deltaX > 0
        let forward = style.settings.direction == .rightToLeft ? draggedRight : !draggedRight
        actions.onSwipeTurn(forward ? .forward : .backward)
    }

    private func handleClick(_ event: NSEvent, style: MangaCanvasStyle) {
        if style.isPopupOpen {
            pendingMenuToggle?.cancel()
            actions.onDismissOCRSelection()
            return
        }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let visible = contentView.bounds
        let normalized = CGPoint(
            x: (point.x - visible.minX) / max(visible.width, 1),
            y: contentView.isFlipped
                ? (point.y - visible.minY) / max(visible.height, 1)
                : 1 - (point.y - visible.minY) / max(visible.height, 1)
        )
        let action = style.settings.tapZoneAction(at: normalized)
        if event.clickCount >= 2 {
            pendingMenuToggle?.cancel()
            pendingMenuToggle = nil
            guard action == nil || action == .menu else { return }
            if style.settings.doubleClickZoom {
                toggleDoubleClickZoom(at: event, animated: style.settings.animatesDoubleClickZoom)
            }
            return
        }
        switch action {
        case .previous?, .next?:
            pendingMenuToggle?.cancel()
            actions.onTapZone(action!)
        case .menu?:
            pendingMenuToggle?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.actions.onTapZone(.menu)
            }
            pendingMenuToggle = work
            let delay = style.settings.doubleClickZoom ? NSEvent.doubleClickInterval : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case nil:
            break
        }
    }

    private func toggleDoubleClickZoom(at event: NSEvent, animated: Bool) {
        let fit = baseMagnification()
        guard fit > 0 else { return }
        let currentScale = magnification / fit
        let targetScale: CGFloat = currentScale > 1.01 ? 1 : 2
        let pointInClipView = contentView.convert(event.locationInWindow, from: nil)
        let pointInDocument = spreadView.convert(pointInClipView, from: contentView)
        requestedZoomScale = targetScale
        lastAppliedFitMagnification = fit * targetScale
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                animator().setMagnification(fit * targetScale, centeredAt: pointInDocument)
            }
        } else {
            setMagnification(fit * targetScale, centeredAt: pointInDocument)
        }
        actions.onZoomScaleChange(Double(targetScale))
    }

    private var documentExceedsViewport: Bool {
        let documentSize = spreadView.frame.size
        let visible = contentView.bounds.size
        return documentSize.width > visible.width + 1
            || documentSize.height > visible.height + 1
    }

    private func canScroll(toward navigation: MangaWheelNavigation) -> Bool {
        let document = spreadView.frame
        let visible = contentView.bounds
        guard document.height > visible.height + 1 else { return false }
        // The document view is flipped: forward (wheel down) moves toward a
        // larger origin.
        switch navigation {
        case .forward:
            return visible.maxY < document.maxY - 1
        case .backward:
            return visible.minY > document.minY + 1
        }
    }

    private func pan(windowDelta: CGPoint) {
        let scale = max(magnification, 0.01)
        var origin = contentView.bounds.origin
        origin.x -= windowDelta.x / scale
        origin.y += windowDelta.y / scale
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func perform(_ command: MangaCanvasCommand) {
        switch command.kind {
        case let .pan(dx, dy):
            let visible = contentView.bounds
            var origin = visible.origin
            origin.x += visible.width * dx
            origin.y += visible.height * dy
            contentView.scroll(to: origin)
            reflectScrolledClipView(contentView)
        case let .focusPanel(pageOffset, rect):
            guard let pageFrame = spreadView.pageFrame(at: pageOffset) else { return }
            let target = CGRect(
                x: pageFrame.minX + rect.minX * pageFrame.width,
                y: pageFrame.minY + rect.minY * pageFrame.height,
                width: rect.width * pageFrame.width,
                height: rect.height * pageFrame.height
            )
            let viewport = contentSize
            guard target.width > 0, target.height > 0 else { return }
            let magnificationTarget = min(
                viewport.width / target.width,
                viewport.height / target.height
            ) * 0.9
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                animator().setMagnification(
                    min(maxMagnification, max(minMagnification, magnificationTarget)),
                    centeredAt: CGPoint(x: target.midX, y: target.midY)
                )
            }
        case .resetZoom:
            updateFitMagnification(apply: true)
        }
    }

    private func topLeadingRect(_ documentRect: CGRect) -> CGRect {
        let localRect = convert(documentRect, from: spreadView)
        let localY = isFlipped
            ? localRect.minY
            : bounds.height - localRect.maxY
        return CGRect(
            x: localRect.minX,
            y: localY,
            width: localRect.width,
            height: localRect.height
        )
    }

    private func addPageTransition(turn: MangaPageTurn, animation: MangaPageAnimation) {
        guard animation != .none, let layer else { return }
        let transition = CATransition()
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        switch animation {
        case .slide:
            transition.type = .push
            transition.duration = 0.18
            let forward = turn == .forward
            if isVerticalPaging {
                transition.subtype = forward ? .fromTop : .fromBottom
            } else {
                let rightToLeft = style?.settings.direction == .rightToLeft
                // The next page slides in from the side the reader moves
                // toward: from the left in right-to-left books.
                if rightToLeft {
                    transition.subtype = forward ? .fromLeft : .fromRight
                } else {
                    transition.subtype = forward ? .fromRight : .fromLeft
                }
            }
        case .fade:
            transition.type = .fade
            transition.duration = 0.16
        case .none:
            return
        }
        layer.add(transition, forKey: "mangaPageTurn")
    }

    private func scrollToEntryEdge(_ edge: MangaPageEntryEdge) {
        let document = spreadView.frame
        let visible = contentView.bounds
        guard document.height > visible.height + 1 else { return }
        var origin = visible.origin
        origin.y = edge == .start ? document.minY : document.maxY - visible.height
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }

    private func handleModifierWheelZoom(_ event: NSEvent) -> Bool {
        guard let style else { return false }
        let fit = baseMagnification()
        guard fit > 0 else { return false }
        let currentScale = Double(magnification / max(fit, 0.001))
        guard let targetScale = style.wheelZoomScale(
            from: currentScale,
            event: event
        ) else {
            return false
        }

        let pointInClipView = contentView.convert(event.locationInWindow, from: nil)
        let pointInDocument = spreadView.convert(pointInClipView, from: contentView)
        let targetMagnification = fit * CGFloat(targetScale)
        requestedZoomScale = CGFloat(targetScale)
        lastAppliedFitMagnification = targetMagnification
        setMagnification(targetMagnification, centeredAt: pointInDocument)
        actions.onDismissOCRSelection()
        actions.onZoomScaleChange(targetScale)
        return true
    }

    /// The magnification that represents 100% for the selected page scaling.
    private func baseMagnification() -> CGFloat {
        let viewportSize = contentSize
        guard viewportSize.width > 0, viewportSize.height > 0 else { return 0 }
        let scaleType = style?.settings.scaleType ?? .fitScreen
        if scaleType == .stretch {
            spreadView.setStretchSize(viewportSize)
            return 1
        }
        spreadView.setStretchSize(nil)
        let imageSize = spreadView.frame.size
        guard imageSize.width > 0, imageSize.height > 0 else { return 0 }
        switch scaleType {
        case .fitScreen, .stretch:
            return min(
                viewportSize.width / imageSize.width,
                viewportSize.height / imageSize.height
            )
        case .fitWidth:
            return viewportSize.width / imageSize.width
        case .fitHeight:
            return viewportSize.height / imageSize.height
        case .original:
            return 1
        }
    }

    private func updateFitMagnification(apply: Bool) {
        let fit = baseMagnification()
        guard fit > 0 else { return }
        let target = fit * requestedZoomScale
        let minimumScale = CGFloat(style?.minimumZoomScale ?? 0.5)
        let maximumScale = CGFloat(style?.maximumZoomScale ?? 4)
        maxMagnification = max(fit * maximumScale, fit)
        minMagnification = min(fit * minimumScale, target)
        lastAppliedFitMagnification = target
        guard apply else {
            contentView.needsDisplay = true
            return
        }
        isUpdatingFit = true
        let imageSize = spreadView.frame.size
        setMagnification(target, centeredAt: NSPoint(
            x: imageSize.width / 2,
            y: imageSize.height / 2
        ))
        isUpdatingFit = false
        contentView.needsDisplay = true
    }
}

// MARK: - Spread document

final class MangaSpreadDocumentView: NSView {
    private struct ContextPage {
        let index: Int
        let image: NSImage
        let frame: CGRect
    }

    fileprivate struct DisplayRegion {
        let region: MangaOCRTextRegion
        let rect: NSRect
    }

    private static let pageSpacing: CGFloat = 8
    private var images: [NSImage] = []
    private var pageIndices: [Int] = []
    private var sourcePageIndices: [Int] = []
    private var ocrRegions: [Int: [MangaOCRTextRegion]] = [:]
    fileprivate var displayRegions: [DisplayRegion] = []
    fileprivate var selectedRegionID: String?
    fileprivate var selectedMatchedLength = 0
    fileprivate var hoveredRegionID: String?
    private var lastHoverLookupRegionID: String?
    private var lastHoverLookupPoint: CGPoint?
    private var lastMousePoint: CGPoint?
    private var onSelection: ((MangaOCRTextRegion, CGRect) -> Int?)?
    private var onDismissSelection: (() -> Void)?
    private var hoverTrackingArea: NSTrackingArea?
    private var pageImageViews: [NSImageView] = []
    private var colorOverlayViews: [NSView] = []
    private let overlayView = MangaOCROverlayView()
    private var fitsSinglePageToBounds = false
    private var stretchSize: CGSize?
    private var lastLayoutSize: NSSize = .zero
    private var contextPage: ContextPage?
    private var contextMenuAnchor = CGRect.zero
    private var sharingPicker: NSSharingServicePicker?
    private var continuousZoomScale: Double?
    private var onContinuousZoomScaleChange: ((Double) -> Void)?
    private var style: MangaCanvasStyle?
    weak var interactionHost: MangaCanvasInteractionHost?
    var actions = MangaCanvasActions()
    var onSetCover: ((Int) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        overlayView.owner = self
        addSubview(overlayView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setFitsSinglePageToBounds() {
        fitsSinglePageToBounds = true
    }

    func setStretchSize(_ size: CGSize?) {
        guard stretchSize != size else { return }
        stretchSize = size
        resizeToContent()
        rebuildPageImageViews()
        rebuildDisplayRegions()
    }

    func configureContinuousZoom(
        scale: Double,
        onScaleChange: @escaping (Double) -> Void
    ) {
        continuousZoomScale = scale
        onContinuousZoomScaleChange = onScaleChange
    }

    func applyStyle(_ style: MangaCanvasStyle) {
        let previous = self.style
        self.style = style
        guard previous?.settings != style.settings else { return }
        applyImageStyle()
        overlayView.needsDisplay = true
    }

    func pageFrame(at offset: Int) -> CGRect? {
        let frames = pageFrames
        return frames.indices.contains(offset) ? frames[offset] : nil
    }

    func setImages(
        _ images: [NSImage],
        pageIndices: [Int],
        sourcePageIndices: [Int]
    ) {
        let imagesChanged = self.images.count != images.count
            || !zip(self.images, images).allSatisfy { $0.0 === $0.1 }
        guard imagesChanged
                || self.pageIndices != pageIndices
                || self.sourcePageIndices != sourcePageIndices else {
            return
        }
        self.images = images
        self.pageIndices = pageIndices
        self.sourcePageIndices = sourcePageIndices
        resizeToContent()
        rebuildPageImageViews()
        rebuildDisplayRegions()
        overlayView.needsDisplay = true
    }

    private func resizeToContent() {
        guard !fitsSinglePageToBounds else { return }
        if let stretchSize {
            frame = NSRect(origin: .zero, size: stretchSize)
            return
        }
        let width = images.reduce(0) { $0 + $1.size.width }
            + Self.pageSpacing * CGFloat(max(0, images.count - 1))
        let height = images.map(\.size.height).max() ?? 0
        frame = NSRect(x: 0, y: 0, width: width, height: height)
    }

    override func layout() {
        super.layout()
        overlayView.frame = bounds
        guard fitsSinglePageToBounds,
              bounds.size != lastLayoutSize else {
            return
        }
        lastLayoutSize = bounds.size
        rebuildPageImageViews()
        rebuildDisplayRegions()
        overlayView.needsDisplay = true
    }

    func setOCRRegions(
        _ regions: [Int: [MangaOCRTextRegion]],
        pageIndices: [Int],
        showsSelection: Bool,
        onDismissSelection: @escaping () -> Void,
        onSelection: @escaping (MangaOCRTextRegion, CGRect) -> Int?
    ) {
        ocrRegions = regions
        self.pageIndices = pageIndices
        self.onSelection = onSelection
        self.onDismissSelection = onDismissSelection
        if regions.isEmpty || !showsSelection {
            selectedRegionID = nil
            selectedMatchedLength = 0
            lastHoverLookupRegionID = nil
        }
        rebuildDisplayRegions()
        overlayView.needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        let zoomModifiers: NSEvent.ModifierFlags = [.command, .control]
        guard let continuousZoomScale,
              !event.modifierFlags.intersection(zoomModifiers).isEmpty,
              event.modifierFlags.intersection([.option, .shift]).isEmpty,
              let targetScale = (style.flatMap {
                  $0.wheelZoomScale(from: continuousZoomScale, event: event)
              } ?? MangaWheelZoomResolver.scale(
                  currentScale: continuousZoomScale,
                  deltaX: event.scrollingDeltaX,
                  deltaY: event.scrollingDeltaY,
                  hasPreciseScrollingDeltas: event.hasPreciseScrollingDeltas
              )) else {
            super.scrollWheel(with: event)
            return
        }
        self.continuousZoomScale = targetScale
        onDismissSelection?()
        onContinuousZoomScaleChange?(targetScale)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let displayRegion = hitRegion(at: point) else {
            if let interactionHost {
                interactionHost.canvasBlankMouseDown(event, in: self)
            } else {
                selectedRegionID = nil
                selectedMatchedLength = 0
                onDismissSelection?()
                overlayView.needsDisplay = true
                super.mouseDown(with: event)
            }
            return
        }
        // Clicking the looked-up character again closes the dictionary, as
        // in Fushi.
        if displayRegion.region.id == selectedRegionID, style?.isPopupOpen == true {
            selectedRegionID = nil
            selectedMatchedLength = 0
            onDismissSelection?()
            overlayView.needsDisplay = true
            return
        }
        select(displayRegion)
    }

    private func select(_ displayRegion: DisplayRegion) {
        selectedRegionID = displayRegion.region.id
        let anchorRect = blockRect(for: displayRegion.region)
        selectedMatchedLength = onSelection?(displayRegion.region, anchorRect) ?? 0
        if selectedMatchedLength == 0 {
            selectedRegionID = nil
        }
        overlayView.needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(at: point),
              let window = event.window,
              let scrollView = ancestorScrollView else {
            super.rightMouseDown(with: event)
            return
        }

        let initialLocation = event.locationInWindow
        var previousLocation = initialLocation
        var isDragging = false
        while let nextEvent = window.nextEvent(
            matching: [.rightMouseDragged, .rightMouseUp]
        ) {
            switch nextEvent.type {
            case .rightMouseDragged:
                let location = nextEvent.locationInWindow
                if !isDragging {
                    let distance = hypot(
                        location.x - initialLocation.x,
                        location.y - initialLocation.y
                    )
                    if distance >= 4 {
                        isDragging = true
                        NSCursor.closedHand.push()
                        onDismissSelection?()
                    }
                }
                if isDragging {
                    pan(
                        scrollView,
                        windowDelta: CGPoint(
                            x: location.x - previousLocation.x,
                            y: location.y - previousLocation.y
                        )
                    )
                }
                previousLocation = location
            case .rightMouseUp:
                if isDragging {
                    NSCursor.pop()
                } else {
                    showContextMenu(for: page, event: event)
                }
                return
            default:
                continue
            }
        }
        if isDragging {
            NSCursor.pop()
        }
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        lastMousePoint = point
        let hit = hitRegion(at: point)
        if hit?.region.id != hoveredRegionID {
            hoveredRegionID = hit?.region.id
            overlayView.needsDisplay = true
        }
        hoverLookup(hit, at: point, modifiers: event.modifierFlags)
    }

    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard event.modifierFlags.contains(.shift),
              let lastMousePoint else {
            return
        }
        lastHoverLookupRegionID = nil
        hoverLookup(hitRegion(at: lastMousePoint), at: lastMousePoint, modifiers: event.modifierFlags)
    }

    /// Fushi looks up on hover while Shift is held, or always when hover
    /// lookup is enabled; the pointer must move 4 points before re-triggering.
    private func hoverLookup(
        _ hit: DisplayRegion?,
        at point: CGPoint,
        modifiers: NSEvent.ModifierFlags
    ) {
        guard let hit,
              style?.settings.looksUpOnHover == true || modifiers.contains(.shift),
              hit.region.id != selectedRegionID,
              hit.region.id != lastHoverLookupRegionID else {
            return
        }
        if let lastHoverLookupPoint,
           hypot(point.x - lastHoverLookupPoint.x, point.y - lastHoverLookupPoint.y) < 4 {
            return
        }
        lastHoverLookupRegionID = hit.region.id
        lastHoverLookupPoint = point
        select(hit)
    }

    override func mouseExited(with event: NSEvent) {
        lastMousePoint = nil
        guard hoveredRegionID != nil else { return }
        hoveredRegionID = nil
        overlayView.needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for displayRegion in displayRegions {
            addCursorRect(displayRegion.rect, cursor: .pointingHand)
        }
    }

    private func rebuildDisplayRegions() {
        var regions: [DisplayRegion] = []
        for (offset, pageFrame) in pageFrames.enumerated() {
            guard pageIndices.indices.contains(offset) else { continue }
            let pageIndex = pageIndices[offset]
            for region in ocrRegions[pageIndex] ?? [] {
                let normalized = region.normalizedBounds
                let rect = CGRect(
                    x: pageFrame.minX + normalized.minX * pageFrame.width,
                    y: pageFrame.minY + (1 - normalized.maxY) * pageFrame.height,
                    width: normalized.width * pageFrame.width,
                    height: normalized.height * pageFrame.height
                )
                guard rect.width > 0, rect.height > 0 else { continue }
                regions.append(DisplayRegion(region: region, rect: rect))
            }
        }
        displayRegions = regions
        discardCursorRects()
        window?.invalidateCursorRects(for: self)
    }

    private func rebuildPageImageViews() {
        pageImageViews.forEach { $0.removeFromSuperview() }
        colorOverlayViews.forEach { $0.removeFromSuperview() }
        pageImageViews = []
        colorOverlayViews = []
        for (image, pageFrame) in zip(images, pageFrames) {
            let imageView = NSImageView(frame: pageFrame)
            imageView.image = image
            imageView.imageScaling = .scaleAxesIndependently
            imageView.imageAlignment = .alignCenter
            imageView.wantsLayer = true
            imageView.layerUsesCoreImageFilters = true
            addSubview(imageView, positioned: .below, relativeTo: overlayView)
            pageImageViews.append(imageView)

            let colorOverlay = NSView(frame: pageFrame)
            colorOverlay.wantsLayer = true
            addSubview(colorOverlay, positioned: .below, relativeTo: overlayView)
            colorOverlayViews.append(colorOverlay)
        }
        applyImageStyle()
    }

    private func applyImageStyle() {
        let filters = style?.imageFilters ?? []
        for imageView in pageImageViews {
            imageView.contentFilters = filters
        }
        let overlayColor = style?.settings.customColorFilterColor
        for overlay in colorOverlayViews {
            overlay.isHidden = overlayColor == nil
            overlay.layer?.backgroundColor = overlayColor?.cgColor
        }
    }

    private func page(at point: CGPoint) -> ContextPage? {
        for offset in pageFrames.indices where pageFrames[offset].contains(point) {
            guard images.indices.contains(offset),
                  sourcePageIndices.indices.contains(offset) else {
                continue
            }
            return ContextPage(
                index: sourcePageIndices[offset],
                image: images[offset],
                frame: pageFrames[offset]
            )
        }
        return nil
    }

    private var ancestorScrollView: NSScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? NSScrollView {
                return scrollView
            }
            candidate = view.superview
        }
        return enclosingScrollView
    }

    private func pan(_ scrollView: NSScrollView, windowDelta: CGPoint) {
        let scale = max(scrollView.magnification, 0.01)
        var origin = scrollView.contentView.bounds.origin
        origin.x -= windowDelta.x / scale
        if scrollView.documentView?.isFlipped == true {
            origin.y += windowDelta.y / scale
        } else {
            origin.y -= windowDelta.y / scale
        }
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private func showContextMenu(for page: ContextPage, event: NSEvent) {
        contextPage = page
        let point = convert(event.locationInWindow, from: nil)
        contextMenuAnchor = CGRect(x: point.x, y: point.y, width: 1, height: 1)

        let menu = NSMenu()
        menu.addItem(menuItem(
            title: String(localized: "Previous Page"),
            systemImage: "arrow.backward",
            action: #selector(previousPage)
        ))
        menu.addItem(menuItem(
            title: String(localized: "Next Page"),
            systemImage: "arrow.forward",
            action: #selector(nextPage)
        ))
        menu.addItem(menuItem(
            title: String(localized: "Jump to Page…"),
            systemImage: "number",
            action: #selector(jumpToPage)
        ))
        menu.addItem(menuItem(
            title: String(localized: "Switch Reading Direction"),
            systemImage: "arrow.left.arrow.right",
            action: #selector(toggleDirection)
        ))
        menu.addItem(menuItem(
            title: String(localized: "Zoom In"),
            systemImage: "plus.magnifyingglass",
            action: #selector(zoomIn)
        ))
        menu.addItem(menuItem(
            title: String(localized: "Zoom Out"),
            systemImage: "minus.magnifyingglass",
            action: #selector(zoomOut)
        ))
        menu.addItem(.separator())
        menu.addItem(menuItem(
            title: String(localized: "Copy Page Image"),
            systemImage: "document.on.document",
            action: #selector(copyPageImage)
        ))
        menu.addItem(menuItem(
            title: String(localized: "Save Page Image…"),
            systemImage: "square.and.arrow.down",
            action: #selector(savePageImage)
        ))
        menu.addItem(menuItem(
            title: String(localized: "Share Page Image…"),
            systemImage: "square.and.arrow.up",
            action: #selector(sharePageImage)
        ))
        if onSetCover != nil {
            menu.addItem(.separator())
            menu.addItem(menuItem(
                title: String(localized: "Set as Manga Cover"),
                systemImage: "photo.badge.checkmark",
                action: #selector(setAsCover)
            ))
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    private func menuItem(
        title: String,
        systemImage: String,
        action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        return item
    }

    @objc private func previousPage() { actions.onPreviousPage() }
    @objc private func nextPage() { actions.onNextPage() }
    @objc private func jumpToPage() { actions.onJumpToPage() }
    @objc private func toggleDirection() { actions.onToggleDirection() }
    @objc private func zoomIn() { actions.onZoomStep(10) }
    @objc private func zoomOut() { actions.onZoomStep(-10) }

    @objc private func copyPageImage() {
        guard let image = contextPage?.image else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @objc private func savePageImage() {
        guard let contextPage,
              let tiffData = contextPage.image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffData),
              let pngData = representation.representation(using: .png, properties: [:]) else {
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let pageName = String(
            format: String(localized: "Page %lld"),
            Int64(contextPage.index + 1)
        )
        panel.nameFieldStringValue = "\(pageName).png"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try pngData.write(to: url, options: .atomic)
            } catch {
                NSApplication.shared.presentError(error)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @objc private func sharePageImage() {
        guard let image = contextPage?.image else { return }
        let picker = NSSharingServicePicker(items: [image])
        sharingPicker = picker
        picker.show(
            relativeTo: contextMenuAnchor,
            of: self,
            preferredEdge: .minY
        )
    }

    @objc private func setAsCover() {
        guard let pageIndex = contextPage?.index else { return }
        onSetCover?(pageIndex)
    }

    private var pageFrames: [CGRect] {
        if fitsSinglePageToBounds, let image = images.first {
            let widthScale = bounds.width / max(image.size.width, 1)
            let heightScale = bounds.height / max(image.size.height, 1)
            let scale = min(widthScale, heightScale)
            let size = CGSize(
                width: image.size.width * scale,
                height: image.size.height * scale
            )
            return [CGRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )]
        }

        if let stretchSize, !images.isEmpty {
            // Stretch fills the viewport; each page keeps its share of the
            // spread width.
            let spacing = Self.pageSpacing * CGFloat(max(0, images.count - 1))
            let totalWidth = max(images.reduce(0) { $0 + $1.size.width }, 1)
            var frames: [CGRect] = []
            var x: CGFloat = 0
            for image in images {
                let width = (stretchSize.width - spacing) * image.size.width / totalWidth
                frames.append(CGRect(x: x, y: 0, width: width, height: stretchSize.height))
                x += width + Self.pageSpacing
            }
            return frames
        }

        var frames: [CGRect] = []
        var x: CGFloat = 0
        for image in images {
            frames.append(CGRect(
                x: x,
                y: (bounds.height - image.size.height) / 2,
                width: image.size.width,
                height: image.size.height
            ))
            x += image.size.width + Self.pageSpacing
        }
        return frames
    }

    /// Mirrors Mangatan/Chimahon's native canvas behavior: passive OCR regions
    /// remain invisible, while hovering or tapping reveals the complete OCR
    /// paragraph and the dictionary match receives a restrained accent highlight.
    private func hitRegion(at point: CGPoint) -> DisplayRegion? {
        let hitSlop = 4 / max(enclosingScrollView?.magnification ?? 1, 0.01)
        return displayRegions
            .filter({ $0.rect.insetBy(dx: -hitSlop, dy: -hitSlop).contains(point) })
            .min(by: { $0.rect.width * $0.rect.height < $1.rect.width * $1.rect.height })
    }

    private func blockRect(for region: MangaOCRTextRegion) -> CGRect {
        displayRegions
            .lazy
            .filter {
                $0.region.pageIndex == region.pageIndex
                    && $0.region.blockID == region.blockID
            }
            .map(\.rect)
            .reduce(CGRect.null) { $0.union($1) }
    }

    fileprivate func drawOverlay() {
        if style?.settings.showsOCRBoxes == true {
            drawOCRBoxes()
        }
        drawOCRTextOverlay()
    }

    /// Fushi's "show recognized text regions": red block outlines and dashed
    /// blue character outlines.
    private func drawOCRBoxes() {
        let blocks = Dictionary(grouping: displayRegions) {
            "\($0.region.pageIndex)|\($0.region.blockID)"
        }
        NSColor.systemRed.withAlphaComponent(0.85).setStroke()
        for regions in blocks.values {
            let rect = regions.map(\.rect).reduce(CGRect.null) { $0.union($1) }
            guard !rect.isNull else { continue }
            let path = NSBezierPath(rect: rect.insetBy(dx: -1, dy: -1))
            path.lineWidth = 1.5
            path.stroke()
        }
        NSColor.systemBlue.withAlphaComponent(0.7).setStroke()
        for displayRegion in displayRegions {
            let path = NSBezierPath(rect: displayRegion.rect)
            path.lineWidth = 0.75
            path.setLineDash([3, 2], count: 2, phase: 0)
            path.stroke()
        }
    }

    private func drawOCRTextOverlay() {
        let visibleRegionID = selectedRegionID ?? hoveredRegionID
        guard let selected = displayRegions.first(where: {
            $0.region.id == visibleRegionID
        }) else {
            return
        }
        let activeRegions = displayRegions
            .filter {
                $0.region.pageIndex == selected.region.pageIndex
                    && $0.region.blockID == selected.region.blockID
            }
            .sorted { $0.region.utf16Offset < $1.region.utf16Offset }
        let matchRange = NSRange(
            location: selected.region.utf16Offset,
            length: selectedRegionID == nil ? 0 : selectedMatchedLength
        )
        let sentence = selected.region.sentence as NSString

        let lines = Dictionary(grouping: activeRegions, by: \.region.lineID)
            .values
            .sorted {
                ($0.map(\.region.utf16Offset).min() ?? 0)
                    < ($1.map(\.region.utf16Offset).min() ?? 0)
            }
        for lineRegions in lines {
            let ordered = lineRegions.sorted {
                $0.region.utf16Offset < $1.region.utf16Offset
            }
            guard let first = ordered.first,
                  let last = ordered.last else {
                continue
            }
            let lineRect = ordered
                .map(\.rect)
                .reduce(CGRect.null) { $0.union($1) }
            guard !lineRect.isNull, lineRect.width > 0, lineRect.height > 0 else {
                continue
            }

            NSColor.white.withAlphaComponent(0.72).setFill()
            NSBezierPath(rect: lineRect).fill()
            for displayRegion in ordered {
                let characterRange = sentence.rangeOfComposedCharacterSequence(
                    at: displayRegion.region.utf16Offset
                )
                if NSIntersectionRange(characterRange, matchRange).length > 0 {
                    NSColor.controlAccentColor.withAlphaComponent(0.45).setFill()
                    NSBezierPath(rect: displayRegion.rect).fill()
                }
            }

            let lastRange = sentence.rangeOfComposedCharacterSequence(
                at: last.region.utf16Offset
            )
            let lineRange = NSRange(
                location: first.region.utf16Offset,
                length: NSMaxRange(lastRange) - first.region.utf16Offset
            )
            let lineText = sentence.substring(with: lineRange)
            if selected.region.isVertical {
                drawVerticalOCRText(
                    sentence: sentence,
                    regions: ordered
                )
            } else {
                drawHorizontalOCRText(lineText, in: lineRect)
            }
        }
    }

    private func drawHorizontalOCRText(_ text: String, in rect: CGRect) {
        guard !text.isEmpty else { return }
        let attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: 20, weight: .regular),
                .foregroundColor: NSColor.black,
            ]
        )
        let textSize = attributedText.size()
        guard textSize.width > 0, textSize.height > 0 else { return }
        let scale = min(rect.width / textSize.width, rect.height / textSize.height)

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: rect.midX, yBy: rect.midY)
        transform.scale(by: scale)
        transform.translateX(by: -textSize.width / 2, yBy: -textSize.height / 2)
        transform.concat()
        attributedText.draw(at: .zero)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawVerticalOCRText(
        sentence: NSString,
        regions: [DisplayRegion]
    ) {
        for displayRegion in regions {
            let offset = displayRegion.region.utf16Offset
            guard offset >= 0, offset < sentence.length else { continue }
            let characterRange = sentence.rangeOfComposedCharacterSequence(at: offset)
            let text = sentence.substring(with: characterRange)
            let rect = displayRegion.rect
            let fontSize = max(8, min(rect.width * 0.82, rect.height * 0.95))
            let attributedText = NSAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
                    .foregroundColor: NSColor.black,
                ]
            )
            let textSize = attributedText.size()
            attributedText.draw(at: NSPoint(
                x: rect.midX - textSize.width / 2,
                y: rect.midY - textSize.height / 2
            ))
        }
    }
}

/// Draws OCR hover/selection text and region outlines above the page images,
/// while letting every mouse event reach the document view below.
private final class MangaOCROverlayView: NSView {
    weak var owner: MangaSpreadDocumentView?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        owner?.drawOverlay()
    }
}

final class MangaCenteredClipView: NSClipView {
    weak var interactionHost: MangaCanvasInteractionHost?

    override func mouseDown(with event: NSEvent) {
        if let interactionHost {
            interactionHost.canvasBlankMouseDown(event, in: self)
            return
        }
        super.mouseDown(with: event)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return bounds }
        if documentView.frame.width < bounds.width {
            bounds.origin.x = (documentView.frame.width - bounds.width) / 2
        }
        if documentView.frame.height < bounds.height {
            bounds.origin.y = (documentView.frame.height - bounds.height) / 2
        }
        return bounds
    }
}

// MARK: - Continuous page interaction

/// Click handling for one page of the long-strip reader: click zones scroll
/// by most of a screen, the center toggles the interface, and a double click
/// on a blank area toggles zoom.
@MainActor
final class MangaContinuousInteractionHost: MangaCanvasInteractionHost {
    var style: MangaCanvasStyle?
    var actions = MangaCanvasActions()
    var onScrollPage: (MangaPageTurn) -> Void = { _ in }
    var onDoubleClickZoom: () -> Void = {}
    private var pendingMenuToggle: DispatchWorkItem?

    func canvasBlankMouseDown(_ event: NSEvent, in view: NSView) {
        guard let style else { return }
        if style.isPopupOpen {
            actions.onDismissOCRSelection()
            return
        }
        guard let window = view.window, let contentView = window.contentView else { return }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let bounds = contentView.bounds
        let normalized = CGPoint(
            x: point.x / max(bounds.width, 1),
            y: contentView.isFlipped
                ? point.y / max(bounds.height, 1)
                : 1 - point.y / max(bounds.height, 1)
        )
        let action = style.settings.tapZoneAction(at: normalized)
        if event.clickCount >= 2 {
            pendingMenuToggle?.cancel()
            pendingMenuToggle = nil
            if (action == nil || action == .menu), style.settings.doubleClickZoom {
                onDoubleClickZoom()
            }
            return
        }
        switch action {
        case .next?:
            onScrollPage(.forward)
        case .previous?:
            onScrollPage(.backward)
        case .menu?:
            pendingMenuToggle?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.actions.onTapZone(.menu)
            }
            pendingMenuToggle = work
            let delay = style.settings.doubleClickZoom ? NSEvent.doubleClickInterval : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case nil:
            break
        }
    }
}
