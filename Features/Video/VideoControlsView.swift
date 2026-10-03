import AppKit
import SwiftUI

struct VideoControlsMetrics {
    let chromeSize: CGSize
    let controlHeight: CGFloat
    let popupBottomInset: CGFloat
    let bottomInset: CGFloat
}

/// Playback chrome in two user-selectable layouts:
/// - floating: one draggable Liquid Glass panel with the timeline on top and
///   volume / transport / tools in three centered clusters below;
/// - compactBottom: a full-width bar on a dark scrim, timeline first, then
///   transport and time on the left and tools on the right.
struct VideoControlsView: View {
    let snapshot: VideoPlaybackSnapshot
    let timelinePreview: VideoTimelinePreview?
    let playlist: VideoPlaylist
    let canSaveScreenshot: Bool
    let canMineCurrentSubtitle: Bool
    let isFullScreen: Bool
    let isSubtitleGapFastForwardEnabled: Bool
    var isMiningHistoryVisible = false
    var isInspectorVisible = false
    let layout: VideoControlBarLayout
    let availableWidth: CGFloat
    @Binding var isSpeedPanelVisible: Bool
    var onTogglePlayback: () -> Void
    var onSeek: (TimeInterval) -> Void
    var onPrevious: () -> Void
    var onNext: () -> Void
    var onSetVolume: (Double) -> Void
    var onToggleMuted: () -> Void
    var onSetSpeed: (Double) -> Void
    var onToggleMiningHistory: () -> Void
    var onOpenVideo: () -> Void
    var onSaveScreenshot: () -> Void
    var onMineCurrentSubtitle: () -> Void
    var onToggleSubtitleGapFastForward: () -> Void
    var onToggleInspector: () -> Void
    var onToggleFullScreen: () -> Void
    var onTimelinePreviewTimeChanged: (TimeInterval?) -> Void
    var onDragChanged: (CGSize) -> Void
    var onDragEnded: (CGSize) -> Void

    @State private var scrubTime: TimeInterval = 0
    @State private var isScrubbing = false
    @State private var isProgressPreviewActive = false
    @State private var isProgressHovering = false
    @State private var previewTime: TimeInterval?
    @State private var previewX: CGFloat = 0
    @State private var progressWidth: CGFloat = Self.floatingControlsWidth
    @State private var progressFrame: CGRect = .zero
    @State private var progressPreviewHideTask: Task<Void, Never>?
    @State private var speedInputText = ""

    private static let controlsWidth: CGFloat = 760
    private static let floatingControlsWidth: CGFloat = 760
    private static let floatingControlsHeight: CGFloat = 90
    private static let floatingCornerRadius: CGFloat = 24
    private static let floatingIconSize: CGFloat = 30
    private static let floatingPlaybackButtonSize: CGFloat = 42
    private static let compactIconSize: CGFloat = 30
    private static let compactPlaybackButtonSize: CGFloat = 38
    private static let compactControlsHeight: CGFloat = 84
    static let timelinePreviewChromeHeight: CGFloat = 214
    private static let compactTimelinePreviewChromeHeight: CGFloat = 112
    private static let floatingProgressHorizontalInset: CGFloat = 54
    private static let compactProgressHorizontalInset: CGFloat = 0
    private static let floatingHorizontalPadding: CGFloat = 16
    private static let compactHorizontalPadding: CGFloat = 22
    private static let timelineHitHeight: CGFloat = 18
    private static let timelinePreviewWidth: CGFloat = 76
    private static let timelinePreviewBubbleCenterY: CGFloat = -34
    private static let compactTimelinePreviewBubbleCenterY: CGFloat = -24
    private static let controlsCoordinateSpace = "video-controls"
    private static let speedPanelWidth: CGFloat = 264
    private static let speedPanelHalfHeight: CGFloat = 74
    private static let speedPresetRows = [
        [0.25, 0.5, 1.0, 1.5],
        [2.0, 3.0, 4.0, 5.0]
    ]

    private enum ControlDensity: Equatable {
        case full
        case condensed
        case minimal
    }

    static func metrics(for layout: VideoControlBarLayout) -> VideoControlsMetrics {
        switch layout {
        case .floating:
            VideoControlsMetrics(
                chromeSize: CGSize(width: floatingControlsWidth, height: timelinePreviewChromeHeight),
                controlHeight: floatingControlsHeight,
                popupBottomInset: 56,
                bottomInset: 24
            )
        case .compactBottom:
            VideoControlsMetrics(
                chromeSize: CGSize(width: controlsWidth, height: compactTimelinePreviewChromeHeight),
                controlHeight: compactControlsHeight,
                popupBottomInset: 28,
                bottomInset: 0
            )
        }
    }

    static func chromeSize(
        for layout: VideoControlBarLayout,
        availableWidth: CGFloat
    ) -> CGSize {
        let defaultSize = metrics(for: layout).chromeSize
        guard availableWidth.isFinite, availableWidth > 0 else {
            return defaultSize
        }

        switch layout {
        case .floating:
            return CGSize(
                width: min(floatingControlsWidth, max(availableWidth - 32, 1)),
                height: defaultSize.height
            )
        case .compactBottom:
            return CGSize(width: availableWidth, height: defaultSize.height)
        }
    }

    private var activeChromeWidth: CGFloat {
        Self.chromeSize(for: layout, availableWidth: availableWidth).width
    }

    private var controlDensity: ControlDensity {
        let fullThreshold: CGFloat = layout == .floating ? 680 : 720
        if activeChromeWidth >= fullThreshold {
            return .full
        }
        if activeChromeWidth >= 390 {
            return .condensed
        }
        return .minimal
    }

    private var controlTreatment: VideoControlTreatment {
        switch layout {
        case .floating:
            .floating
        case .compactBottom:
            .compactBottom
        }
    }

    private var iconButtonSize: CGFloat {
        switch layout {
        case .floating:
            Self.floatingIconSize
        case .compactBottom:
            Self.compactIconSize
        }
    }

    private var playbackButtonSize: CGFloat {
        switch layout {
        case .floating:
            Self.floatingPlaybackButtonSize
        case .compactBottom:
            Self.compactPlaybackButtonSize
        }
    }

    private var compactControlForeground: Color {
        Color.white.opacity(0.92)
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            switch layout {
            case .floating:
                floatingControls
                    .modifier(VideoFloatingGlassSurface(cornerRadius: Self.floatingCornerRadius))
                    .zIndex(0)
            case .compactBottom:
                compactBottomControls
                    .zIndex(0)
            }

            if isSpeedPanelVisible {
                speedControlPanel
                    .position(speedPanelPosition)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottomTrailing)))
                    .zIndex(30)
            }

            if let preview = activeTimelinePreview {
                let progressFrame = effectiveProgressFrame
                timelinePreviewBubble(preview)
                    .position(
                        x: progressFrame.minX + clampedPreviewX(in: progressFrame.width),
                        y: progressFrame.minY + timelinePreviewBubbleCenterY
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                    .zIndex(20)
            }
        }
        .coordinateSpace(name: Self.controlsCoordinateSpace)
        .frame(
            width: activeChromeWidth,
            height: Self.metrics(for: layout).chromeSize.height,
            alignment: .bottom
        )
        .animation(.snappy(duration: 0.16), value: isProgressHovering || isScrubbing)
        .onPreferenceChange(VideoProgressFramePreferenceKey.self) { frame in
            progressFrame = frame
        }
        .onChange(of: snapshot.speed) { _, _ in
            synchronizeSpeedInput()
        }
        .onChange(of: controlDensity) { _, density in
            guard density == .minimal, isSpeedPanelVisible else { return }
            withAnimation(.smooth(duration: 0.16)) {
                isSpeedPanelVisible = false
            }
        }
        .onDisappear {
            progressPreviewHideTask?.cancel()
            progressPreviewHideTask = nil
            onTimelinePreviewTimeChanged(nil)
        }
    }

    // MARK: Layouts

    private var floatingControls: some View {
        VStack(spacing: 6) {
            progressControlStrip
            responsivePrimaryControlGroup
        }
        .padding(.horizontal, Self.floatingHorizontalPadding)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background {
            controlDragSurface
        }
        .frame(width: activeChromeWidth, height: Self.floatingControlsHeight)
    }

    private var compactBottomControls: some View {
        VStack(spacing: 8) {
            timelineProgressControl
                .frame(maxWidth: .infinity)
                .frame(height: Self.timelineHitHeight)
                .padding(.horizontal, Self.compactProgressHorizontalInset)

            responsiveCompactControlGroup
        }
        .padding(.horizontal, Self.compactHorizontalPadding)
        .padding(.bottom, 12)
        .frame(width: activeChromeWidth, height: Self.metrics(for: .compactBottom).chromeSize.height, alignment: .bottom)
        .background(alignment: .bottom) {
            compactBottomScrim
        }
    }

    /// Tall enough that white controls stay legible over bright frames.
    private var compactBottomScrim: some View {
        LinearGradient(
            stops: [
                .init(color: Color.black.opacity(0.62), location: 0),
                .init(color: Color.black.opacity(0.38), location: 0.45),
                .init(color: Color.black.opacity(0), location: 1)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
        .frame(height: Self.metrics(for: .compactBottom).chromeSize.height + 48)
        .allowsHitTesting(false)
    }

    private var controlDragSurface: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.black.opacity(0.001))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        onDragChanged(value.translation)
                    }
                    .onEnded { value in
                        onDragEnded(value.translation)
                    }
            )
    }

    /// Volume, transport and tools as three clusters; the outer two share the
    /// remaining width so play/pause stays centered in the panel.
    private var primaryControlGroup: some View {
        HStack(spacing: 8) {
            HStack(spacing: 0) {
                volumeControl
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            episodeControls

            HStack(spacing: 4) {
                Spacer(minLength: 0)
                speedControlButton
                utilityControlGroup
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private var responsivePrimaryControlGroup: some View {
        switch controlDensity {
        case .full:
            primaryControlGroup
        case .condensed:
            condensedControlGroup
        case .minimal:
            minimalControlGroup
        }
    }

    @ViewBuilder
    private var responsiveCompactControlGroup: some View {
        switch controlDensity {
        case .full:
            HStack(spacing: 6) {
                episodeControls

                volumeControl
                    .padding(.leading, 6)

                Text(compactTimeText)
                    .font(.callout.weight(.medium).monospacedDigit())
                    .foregroundStyle(compactControlForeground)
                    .padding(.leading, 8)
                    .fixedSize()

                Spacer(minLength: 0)

                speedControlButton
                utilityControlGroup
            }
        case .condensed:
            condensedControlGroup
        case .minimal:
            minimalControlGroup
        }
    }

    private var condensedControlGroup: some View {
        HStack(spacing: 4) {
            episodeControls
            Spacer(minLength: 4)
            speedControlButton
            openVideoButton
            inspectorButton
            screenshotButton
            fullScreenButton
        }
    }

    private var minimalControlGroup: some View {
        HStack(spacing: 4) {
            Spacer(minLength: 0)
            episodeControls
            Spacer(minLength: 4)
            screenshotButton
            fullScreenButton
        }
    }

    private var utilityControlGroup: some View {
        HStack(spacing: 2) {
            subtitleGapFastForwardButton
            miningHistoryButton
            openVideoButton
            mineCurrentSubtitleButton
            inspectorButton
            screenshotButton
            fullScreenButton
        }
    }

    // MARK: Buttons

    private func iconLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: iconButtonSize, height: iconButtonSize)
    }

    private var subtitleGapFastForwardButton: some View {
        Button(action: onToggleSubtitleGapFastForward) {
            iconLabel("Fast-forward Subtitle Gaps", systemImage: "forward.fill")
        }
        .buttonStyle(VideoGlassIconButtonStyle(treatment: controlTreatment, isActive: isSubtitleGapFastForwardEnabled))
        .help("Fast-forward Subtitle Gaps")
        .accessibilityLabel(Text("Fast-forward Subtitle Gaps"))
        .accessibilityValue(Text(isSubtitleGapFastForwardEnabled ? "On" : "Off"))
    }

    private var miningHistoryButton: some View {
        Button(action: onToggleMiningHistory) {
            iconLabel("Mining History", systemImage: "clock.arrow.circlepath")
        }
        .buttonStyle(VideoGlassIconButtonStyle(treatment: controlTreatment, isActive: isMiningHistoryVisible))
        .help("Mining History")
    }

    private var openVideoButton: some View {
        Button(action: onOpenVideo) {
            iconLabel("Open Video", systemImage: "film")
        }
        .buttonStyle(VideoGlassIconButtonStyle(treatment: controlTreatment))
        .help("Open Video")
    }

    private var mineCurrentSubtitleButton: some View {
        Button(action: onMineCurrentSubtitle) {
            iconLabel("Mine Current Subtitle", systemImage: "tray.and.arrow.down")
        }
        .buttonStyle(VideoGlassIconButtonStyle(treatment: controlTreatment))
        .disabled(!canMineCurrentSubtitle)
        .help("Mine Current Subtitle")
    }

    private var screenshotButton: some View {
        Button(action: onSaveScreenshot) {
            iconLabel("Save Clean Screenshot", systemImage: "camera")
        }
        .buttonStyle(VideoGlassIconButtonStyle(treatment: controlTreatment))
        .disabled(!canSaveScreenshot)
        .help("Save Clean Screenshot")
        .accessibilityLabel(Text("Save Clean Screenshot"))
    }

    private var inspectorButton: some View {
        Button(action: onToggleInspector) {
            iconLabel("Inspector", systemImage: "sidebar.trailing")
        }
        .buttonStyle(VideoGlassIconButtonStyle(treatment: controlTreatment, isActive: isInspectorVisible))
        .help("Inspector")
    }

    private var fullScreenButton: some View {
        Button(action: onToggleFullScreen) {
            Image(systemName: isFullScreen
                ? "arrow.down.right.and.arrow.up.left"
                : "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: iconButtonSize, height: iconButtonSize)
        }
        .buttonStyle(VideoGlassIconButtonStyle(treatment: controlTreatment))
        .help("Toggle Full Screen")
    }

    /// A text pill: the current rate is the label, so the gauge icon only
    /// appears in the panel header.
    private var speedControlButton: some View {
        Button {
            synchronizeSpeedInput()
            withAnimation(.smooth(duration: 0.16)) {
                isSpeedPanelVisible.toggle()
            }
        } label: {
            Text(VideoPlaybackSpeed.label(snapshot.speed))
                .font(.system(size: 12, weight: .bold).monospacedDigit())
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(minWidth: 40)
                .frame(height: 24)
        }
        .buttonStyle(VideoSpeedControlButtonStyle(treatment: controlTreatment, isActive: isSpeedPanelVisible))
        .padding(.horizontal, 2)
        .help("Playback Speed")
        .accessibilityLabel(Text("Playback Speed"))
        .accessibilityValue(Text(VideoPlaybackSpeed.label(snapshot.speed)))
    }

    private var speedControlPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Playback Speed", systemImage: "speedometer")
                    .font(.callout.weight(.semibold))
                    .labelStyle(.titleAndIcon)

                Spacer(minLength: 0)

                Text(VideoPlaybackSpeed.label(snapshot.speed))
                    .font(.callout.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(Self.speedPresetRows, id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(row, id: \.self) { speed in
                            Button {
                                setSpeed(speed)
                            } label: {
                                Text(Self.speedLabel(speed))
                                    .font(.caption.weight(.semibold).monospacedDigit())
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 26)
                            }
                            .buttonStyle(VideoSpeedPresetButtonStyle(isSelected: isSpeedSelected(speed)))
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Slider(
                    value: Binding<Double>(
                        get: { sliderSpeed },
                        set: { setSpeed($0) }
                    ),
                    in: VideoPlaybackSpeed.customInputLowerBound...VideoPlaybackSpeed.maximum,
                    step: VideoPlaybackSpeed.customStep
                )
                .controlSize(.small)

                HStack(spacing: 3) {
                    TextField("Custom", text: $speedInputText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .frame(width: 44)
                        .onSubmit {
                            commitSpeedInput()
                        }
                    Text(verbatim: "x")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .modifier(VideoControlsTextFieldGlassSurface(cornerRadius: 10))
            }
        }
        .padding(14)
        .frame(width: Self.speedPanelWidth)
        .modifier(VideoFloatingGlassSurface(cornerRadius: 20))
        .onAppear {
            synchronizeSpeedInput()
        }
    }

    // MARK: Timeline

    private var progressControlStrip: some View {
        HStack(spacing: 10) {
            Text(VideoTimeFormatter.string(from: isScrubbing ? scrubTime : snapshot.currentTime))
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.floatingProgressHorizontalInset - 10, alignment: .leading)
                .allowsHitTesting(false)

            timelineProgressControl
                .frame(maxWidth: .infinity)
                .frame(height: Self.timelineHitHeight)

            Text(remainingTimeText)
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Self.floatingProgressHorizontalInset - 10, alignment: .trailing)
                .allowsHitTesting(false)
        }
    }

    private var episodeControls: some View {
        HStack(spacing: layout == .floating ? 10 : 4) {
            Button(action: onPrevious) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: iconButtonSize, height: iconButtonSize)
            }
            .buttonStyle(VideoGlassIconButtonStyle(treatment: controlTreatment))
            .disabled(playlist.previousURL == nil)
            .help("Previous Episode")

            Button(action: onTogglePlayback) {
                Image(systemName: snapshot.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: layout == .floating ? 22 : 20, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: playbackButtonSize, height: playbackButtonSize)
                    .contentShape(Circle())
            }
            .buttonStyle(VideoPlaybackButtonStyle(treatment: controlTreatment))
            .help(snapshot.isPlaying ? "Pause" : "Play")

            Button(action: onNext) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: iconButtonSize, height: iconButtonSize)
            }
            .buttonStyle(VideoGlassIconButtonStyle(treatment: controlTreatment))
            .disabled(playlist.nextURL == nil)
            .help("Next Episode")
        }
    }

    private var displayedProgress: Double {
        guard snapshot.duration > 0 else { return 0 }
        let time = isScrubbing ? scrubTime : snapshot.currentTime
        return min(max(time / snapshot.duration, 0), 1)
    }

    private var timelineProgressControl: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                VideoTimelineTrack(
                    progress: displayedProgress,
                    isEmphasized: isProgressHovering || isScrubbing,
                    treatment: controlTreatment
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background {
                    VideoProgressHoverBridge(
                        onHover: { localX in
                            handleProgressHover(
                                localX: localX,
                                width: geometry.size.width
                            )
                        },
                        onExit: {
                            handleProgressExit()
                        }
                    )
                    .allowsHitTesting(false)
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key: VideoProgressFramePreferenceKey.self,
                                value: proxy.frame(in: .named(Self.controlsCoordinateSpace))
                            )
                    }
                }

                VideoTimelineChapterMarkers(
                    chapters: snapshot.chapters,
                    duration: snapshot.duration,
                    treatment: controlTreatment
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        scrub(toX: value.location.x, width: geometry.size.width)
                    }
                    .onEnded { _ in
                        endScrubbing()
                    }
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    handleProgressHover(
                        localX: location.x,
                        width: geometry.size.width
                    )
                case .ended:
                    handleProgressExit()
                }
            }
            .onAppear {
                progressWidth = geometry.size.width
            }
            .onChange(of: geometry.size) { _, size in
                progressWidth = size.width
            }
            .accessibilityRepresentation {
                Slider(
                    value: Binding(
                        get: { snapshot.currentTime },
                        set: { onSeek(clampedProgressTime($0)) }
                    ),
                    in: 0...max(snapshot.duration, 0.01)
                ) {
                    Text("Playback Position")
                }
                .accessibilityValue(Text(VideoTimeFormatter.string(from: snapshot.currentTime)))
            }
        }
    }

    private func scrub(toX x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        if !isScrubbing {
            isScrubbing = true
            progressPreviewHideTask?.cancel()
            isProgressPreviewActive = true
        }
        let time = progressTime(for: min(max(x, 0), width), width: width)
        scrubTime = time
        updateProgressPreview(time: time)
    }

    private func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        onSeek(scrubTime)
        isProgressPreviewActive = true
        updateProgressPreview(time: scrubTime)
        if !isProgressHovering {
            scheduleProgressPreviewHide()
        }
    }

    private var volumeControl: some View {
        HStack(spacing: 2) {
            Button(action: onToggleMuted) {
                Image(systemName: volumeSymbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: iconButtonSize, height: iconButtonSize)
            }
            .buttonStyle(VideoGlassIconButtonStyle(treatment: controlTreatment))
            .help(snapshot.isMuted ? "Unmute" : "Mute")

            VideoVolumeTrack(
                volume: snapshot.isMuted ? 0 : snapshot.volume,
                treatment: controlTreatment,
                onSetVolume: onSetVolume
            )
            .frame(width: 64, height: Self.timelineHitHeight)
        }
    }

    private var volumeSymbolName: String {
        if snapshot.isMuted || snapshot.volume == 0 {
            return "speaker.slash.fill"
        }
        if snapshot.volume < 34 {
            return "speaker.wave.1.fill"
        }
        if snapshot.volume < 67 {
            return "speaker.wave.2.fill"
        }
        return "speaker.wave.3.fill"
    }

    private static func speedLabel(_ speed: Double) -> String {
        VideoPlaybackSpeed.label(speed)
    }

    private var selectedPresetSpeed: Double {
        let normalizedSpeed = VideoPlaybackSpeed.normalized(snapshot.speed)
        return VideoPlaybackSpeed.presetChoices.first { abs($0 - normalizedSpeed) < 0.001 } ?? normalizedSpeed
    }

    private var sliderSpeed: Double {
        min(
            max(VideoPlaybackSpeed.normalized(snapshot.speed), VideoPlaybackSpeed.customInputLowerBound),
            VideoPlaybackSpeed.maximum
        )
    }

    private func isSpeedSelected(_ speed: Double) -> Bool {
        abs(selectedPresetSpeed - VideoPlaybackSpeed.normalized(speed)) < 0.001
    }

    private func setSpeed(_ speed: Double) {
        let normalizedSpeed = VideoPlaybackSpeed.normalized(speed)
        speedInputText = VideoPlaybackSpeed.label(normalizedSpeed, includesSuffix: false)
        onSetSpeed(normalizedSpeed)
    }

    private func synchronizeSpeedInput() {
        speedInputText = VideoPlaybackSpeed.label(snapshot.speed, includesSuffix: false)
    }

    private func commitSpeedInput() {
        let normalizedText = speedInputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let speed = Double(normalizedText) else {
            synchronizeSpeedInput()
            return
        }
        setSpeed(speed)
    }

    private var remainingTimeText: String {
        let activeTime = isScrubbing ? scrubTime : snapshot.currentTime
        let remaining = max(snapshot.duration - activeTime, 0)
        return "-" + VideoTimeFormatter.string(from: remaining)
    }

    private var compactTimeText: String {
        let activeTime = isScrubbing ? scrubTime : snapshot.currentTime
        return "\(VideoTimeFormatter.string(from: activeTime)) / \(VideoTimeFormatter.string(from: snapshot.duration))"
    }

    private var activeTimelinePreview: VideoTimelinePreview? {
        guard let previewTime, isProgressPreviewActive || isScrubbing else {
            return nil
        }

        if let timelinePreview,
           abs(timelinePreview.time - previewTime) < 0.75 {
            return VideoTimelinePreview(
                time: previewTime,
                pngData: timelinePreview.pngData
            )
        }

        return VideoTimelinePreview(time: previewTime, pngData: nil)
    }

    private var effectiveProgressFrame: CGRect {
        if progressFrame.width > 0 {
            return progressFrame
        }

        switch layout {
        case .floating:
            let controlsTop = Self.timelinePreviewChromeHeight - Self.floatingControlsHeight
            let horizontalPadding = Self.floatingHorizontalPadding * 2
            let progressWidth = max(
                activeChromeWidth - horizontalPadding - Self.floatingProgressHorizontalInset * 2,
                0
            )
            return CGRect(
                x: Self.floatingHorizontalPadding + Self.floatingProgressHorizontalInset,
                y: controlsTop + 12,
                width: progressWidth,
                height: Self.timelineHitHeight
            )
        case .compactBottom:
            let progressWidth = max(
                activeChromeWidth - Self.compactHorizontalPadding * 2,
                0
            )
            return CGRect(
                x: Self.compactHorizontalPadding,
                y: Self.compactTimelinePreviewChromeHeight - Self.compactControlsHeight,
                width: progressWidth,
                height: Self.timelineHitHeight
            )
        }
    }

    /// Opens above the tools cluster at the trailing edge of the controls.
    private var speedPanelPosition: CGPoint {
        let halfWidth = Self.speedPanelWidth / 2
        let trailingLimit = max(activeChromeWidth - halfWidth, halfWidth)
        let controlsTop: CGFloat
        switch layout {
        case .floating:
            controlsTop = Self.timelinePreviewChromeHeight - Self.floatingControlsHeight
        case .compactBottom:
            controlsTop = Self.compactTimelinePreviewChromeHeight - Self.compactControlsHeight
        }
        let trailingInset: CGFloat = layout == .floating ? 8 : Self.compactHorizontalPadding
        return CGPoint(
            x: min(max(activeChromeWidth - halfWidth - trailingInset, halfWidth), trailingLimit),
            y: controlsTop - 10 - Self.speedPanelHalfHeight
        )
    }

    private var timelinePreviewBubbleCenterY: CGFloat {
        switch layout {
        case .floating:
            Self.timelinePreviewBubbleCenterY
        case .compactBottom:
            Self.compactTimelinePreviewBubbleCenterY
        }
    }

    private func handleProgressHover(localX: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        progressPreviewHideTask?.cancel()
        progressPreviewHideTask = nil
        isProgressHovering = true
        isProgressPreviewActive = true
        previewX = min(max(localX, 0), width)
        updateProgressPreview(time: progressTime(for: previewX, width: width))
    }

    private func handleProgressExit() {
        isProgressHovering = false
        guard !isScrubbing else { return }
        if progressPreviewHideTask != nil {
            return
        }
        isProgressPreviewActive = false
        previewTime = nil
        onTimelinePreviewTimeChanged(nil)
    }

    private func updateProgressPreview(time: TimeInterval) {
        let time = clampedProgressTime(time)
        progressPreviewHideTask?.cancel()
        progressPreviewHideTask = nil
        previewX = progressX(for: time, width: progressWidth)
        previewTime = time
        onTimelinePreviewTimeChanged(time)
    }

    private func progressTime(for x: CGFloat, width: CGFloat) -> TimeInterval {
        guard snapshot.duration > 0, width > 0 else { return 0 }
        let progress = min(max(Double(x / width), 0), 1)
        return clampedProgressTime(snapshot.duration * progress)
    }

    private func progressX(for time: TimeInterval, width: CGFloat) -> CGFloat {
        guard snapshot.duration > 0, width > 0 else { return 0 }
        let progress = min(max(time / snapshot.duration, 0), 1)
        return CGFloat(progress) * width
    }

    private func clampedProgressTime(_ time: TimeInterval) -> TimeInterval {
        guard time.isFinite else { return 0 }
        return min(max(time, 0), max(snapshot.duration, 0))
    }

    private func clampedPreviewX(in width: CGFloat) -> CGFloat {
        guard width > Self.timelinePreviewWidth else {
            return max(width / 2, 0)
        }
        let halfWidth = Self.timelinePreviewWidth / 2
        return min(max(previewX, halfWidth), width - halfWidth)
    }

    private func scheduleProgressPreviewHide() {
        progressPreviewHideTask?.cancel()
        progressPreviewHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            guard !isScrubbing, !isProgressHovering else {
                progressPreviewHideTask = nil
                return
            }
            isProgressPreviewActive = false
            previewTime = nil
            progressPreviewHideTask = nil
            onTimelinePreviewTimeChanged(nil)
        }
    }

    private func timelinePreviewBubble(_ preview: VideoTimelinePreview) -> some View {
        Text(VideoTimeFormatter.string(from: preview.time))
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(minWidth: Self.timelinePreviewWidth)
            .glassEffect(.regular, in: Capsule())
    }
}

private struct VideoProgressFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

/// Thin rounded track that thickens and shows its knob while hovered or
/// scrubbed, so the timeline reads as part of the chrome rather than a form
/// slider.
private struct VideoTimelineTrack: View {
    let progress: Double
    let isEmphasized: Bool
    let treatment: VideoControlTreatment
    var restingHeight: CGFloat = 4
    var emphasizedHeight: CGFloat = 7
    var knobSize: CGFloat = 13

    var body: some View {
        GeometryReader { geometry in
            let trackHeight = isEmphasized ? emphasizedHeight : restingHeight
            let filledWidth = geometry.size.width * CGFloat(progress)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(treatment.trackBackground)
                Capsule()
                    .fill(treatment.trackFill)
                    .frame(width: max(trackHeight, filledWidth))
            }
            .frame(height: trackHeight)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                if isEmphasized {
                    Circle()
                        .fill(Color.white)
                        .frame(width: knobSize, height: knobSize)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: min(max(filledWidth - knobSize / 2, -knobSize / 2), geometry.size.width - knobSize / 2))
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }
}

private struct VideoVolumeTrack: View {
    let volume: Double
    let treatment: VideoControlTreatment
    let onSetVolume: (Double) -> Void

    @State private var isHovered = false
    @State private var isDragging = false

    var body: some View {
        GeometryReader { geometry in
            VideoTimelineTrack(
                progress: min(max(volume / 100, 0), 1),
                isEmphasized: isHovered || isDragging,
                treatment: treatment,
                restingHeight: 3,
                emphasizedHeight: 5,
                knobSize: 11
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        setVolume(x: value.location.x, width: geometry.size.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.16), value: isHovered || isDragging)
        .help("Volume")
        .accessibilityRepresentation {
            Slider(
                value: Binding(get: { volume }, set: { onSetVolume($0) }),
                in: 0...100
            ) {
                Text("Volume")
            }
        }
    }

    private func setVolume(x: CGFloat, width: CGFloat) {
        guard width > 0 else { return }
        let fraction = min(max(Double(x / width), 0), 1)
        onSetVolume((fraction * 100).rounded())
    }
}

private struct VideoTimelineChapterMarkers: View {
    let chapters: [VideoChapter]
    let duration: TimeInterval
    let treatment: VideoControlTreatment

    private var markerTimes: [TimeInterval] {
        guard duration.isFinite, duration > 0 else {
            return []
        }

        return chapters
            .sorted { $0.startTime < $1.startTime }
            .reduce(into: [TimeInterval]()) { result, chapter in
                guard chapter.startTime.isFinite,
                      chapter.startTime > 0,
                      chapter.startTime < duration else {
                    return
                }
                guard result.last.map({ abs($0 - chapter.startTime) >= 0.05 }) ?? true else {
                    return
                }
                result.append(chapter.startTime)
            }
    }

    var body: some View {
        GeometryReader { geometry in
            ForEach(markerTimes, id: \.self) { time in
                Capsule(style: .continuous)
                    .fill(treatment.chapterMarker)
                    .frame(width: 2, height: 9)
                    .position(
                        x: markerX(for: time, width: geometry.size.width),
                        y: geometry.size.height / 2
                    )
            }
        }
    }

    private func markerX(for time: TimeInterval, width: CGFloat) -> CGFloat {
        let halfMarkerWidth: CGFloat = 1
        let availableWidth = max(width - halfMarkerWidth * 2, 0)
        return halfMarkerWidth + availableWidth * CGFloat(time / duration)
    }
}

private struct VideoProgressHoverBridge: NSViewRepresentable {
    var onHover: (CGFloat) -> Void
    var onExit: () -> Void

    func makeNSView(context: Context) -> VideoProgressHoverMonitorView {
        let view = VideoProgressHoverMonitorView()
        view.onHover = onHover
        view.onExit = onExit
        return view
    }

    func updateNSView(_ nsView: VideoProgressHoverMonitorView, context: Context) {
        nsView.onHover = onHover
        nsView.onExit = onExit
        nsView.updateMonitorState()
    }
}

private final class VideoProgressHoverMonitorView: NSView {
    var onHover: (CGFloat) -> Void = { _ in }
    var onExit: () -> Void = {}

    nonisolated(unsafe) private var mouseMonitor: Any?
    private var isInside = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateMonitorState()
    }

    deinit {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
    }

    func updateMonitorState() {
        if window == nil {
            removeMouseMonitor()
        } else {
            installMouseMonitor()
        }
    }

    private func installMouseMonitor() {
        guard mouseMonitor == nil else { return }
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
    }

    private func removeMouseMonitor() {
        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
        }
        mouseMonitor = nil
        isInside = false
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard let window, event.window === window else {
            notifyExitIfNeeded()
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else {
            notifyExitIfNeeded()
            return
        }

        isInside = true
        onHover(min(max(location.x, 0), bounds.width))
    }

    private func notifyExitIfNeeded() {
        guard isInside else { return }
        isInside = false
        onExit()
    }
}

private struct VideoFloatingGlassSurface: ViewModifier {
    var cornerRadius: CGFloat = 12

    func body(content: Content) -> some View {
        GlassEffectContainer(spacing: 10) {
            content
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

private enum VideoControlTreatment {
    case floating
    case compactBottom

    func foregroundStyle(isEnabled: Bool) -> AnyShapeStyle {
        switch self {
        case .floating:
            AnyShapeStyle(isEnabled ? .primary : .tertiary)
        case .compactBottom:
            AnyShapeStyle(Color.white.opacity(isEnabled ? 0.94 : 0.34))
        }
    }

    func iconPressedFill(isPressed: Bool) -> Color {
        guard isPressed else { return Color.clear }
        switch self {
        case .floating:
            return Color.primary.opacity(0.16)
        case .compactBottom:
            return Color.white.opacity(0.24)
        }
    }

    var hoverFill: Color {
        switch self {
        case .floating:
            Color.primary.opacity(0.09)
        case .compactBottom:
            Color.white.opacity(0.14)
        }
    }

    var activeFill: Color {
        switch self {
        case .floating:
            Color.primary.opacity(0.16)
        case .compactBottom:
            Color.white.opacity(0.22)
        }
    }

    var trackBackground: Color {
        switch self {
        case .floating:
            Color.primary.opacity(0.18)
        case .compactBottom:
            Color.white.opacity(0.28)
        }
    }

    var trackFill: Color {
        switch self {
        case .floating:
            Color.primary.opacity(0.85)
        case .compactBottom:
            Color.white
        }
    }

    var chapterMarker: Color {
        switch self {
        case .floating:
            Color.primary.opacity(0.55)
        case .compactBottom:
            Color.black.opacity(0.55)
        }
    }

    /// Bare white glyphs need a soft shadow to survive bright frames.
    var glyphShadowOpacity: Double {
        switch self {
        case .floating:
            0
        case .compactBottom:
            0.45
        }
    }
}

/// Hover and active highlight shared by the control button styles.
private struct VideoControlHighlight<S: Shape>: View {
    let shape: S
    let treatment: VideoControlTreatment
    let isPressed: Bool
    let isActive: Bool
    let isHovered: Bool

    var body: some View {
        if isPressed {
            shape.fill(treatment.iconPressedFill(isPressed: true))
        } else if isActive {
            shape.fill(treatment.activeFill)
        } else if isHovered {
            shape.fill(treatment.hoverFill)
        }
    }
}

private struct VideoHoverTrackingLabel<Content: View, S: Shape>: View {
    let shape: S
    let treatment: VideoControlTreatment
    let isPressed: Bool
    let isActive: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        content()
            .foregroundStyle(treatment.foregroundStyle(isEnabled: isEnabled))
            .shadow(color: .black.opacity(treatment.glyphShadowOpacity), radius: 2, y: 0.5)
            .background {
                VideoControlHighlight(
                    shape: shape,
                    treatment: treatment,
                    isPressed: isPressed,
                    isActive: isActive,
                    isHovered: isHovered && isEnabled
                )
            }
            .contentShape(shape)
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovered)
    }
}

private struct VideoGlassIconButtonStyle: ButtonStyle {
    let treatment: VideoControlTreatment
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        VideoHoverTrackingLabel(
            shape: Circle(),
            treatment: treatment,
            isPressed: configuration.isPressed,
            isActive: isActive
        ) {
            configuration.label
        }
        .scaleEffect(configuration.isPressed ? 0.92 : 1)
        .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

private struct VideoSpeedControlButtonStyle: ButtonStyle {
    let treatment: VideoControlTreatment
    var isActive = false

    func makeBody(configuration: Configuration) -> some View {
        VideoHoverTrackingLabel(
            shape: Capsule(),
            treatment: treatment,
            isPressed: configuration.isPressed,
            isActive: isActive
        ) {
            configuration.label
                .overlay {
                    Capsule()
                        .strokeBorder(treatment.trackBackground, lineWidth: 1)
                }
        }
        .scaleEffect(configuration.isPressed ? 0.96 : 1)
        .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}

private struct VideoSpeedPresetButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(isEnabled ? .primary : .tertiary))
            .background {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(buttonFill(isPressed: configuration.isPressed))
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func buttonFill(isPressed: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(isPressed ? 0.8 : 1)
        }
        if isPressed {
            return Color.primary.opacity(0.16)
        }
        return Color.primary.opacity(0.07)
    }
}

private struct VideoControlsTextFieldGlassSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// The play button is the largest control; it keeps a faint resting disc so
/// it stays findable when the panel sits over a busy frame.
private struct VideoPlaybackButtonStyle: ButtonStyle {
    let treatment: VideoControlTreatment

    func makeBody(configuration: Configuration) -> some View {
        VideoHoverTrackingLabel(
            shape: Circle(),
            treatment: treatment,
            isPressed: configuration.isPressed,
            isActive: false
        ) {
            configuration.label
                .background {
                    Circle().fill(treatment.iconPressedFill(isPressed: configuration.isPressed))
                }
        }
        .scaleEffect(configuration.isPressed ? 0.92 : 1)
        .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }
}
