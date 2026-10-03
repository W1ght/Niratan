import AppKit
import SwiftUI

enum VideoInspectorTab: String, CaseIterable, Identifiable {
    case episodes
    case video
    case audio
    case subtitles

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .episodes: "Episodes"
        case .video: "Video"
        case .audio: "Audio"
        case .subtitles: "Subtitles"
        }
    }

    var systemName: String {
        switch self {
        case .episodes: "list.number"
        case .video: "film"
        case .audio: "waveform"
        case .subtitles: "captions.bubble"
        }
    }

    var nativeSegmentTitle: String {
        switch self {
        case .episodes: String(localized: "Episodes")
        case .video: String(localized: "Video")
        case .audio: String(localized: "Audio")
        case .subtitles: String(localized: "Subtitles")
        }
    }
}

/// Floating player inspector: a now-playing header, an icon tab strip, and
/// System Settings–style grouped lists. The panel keeps a single outer glass
/// effect; everything inside is flat fills so playback never re-renders glass.
struct VideoInspectorView: View {
    static let minimumWidth: CGFloat = 300
    static let idealWidth: CGFloat = 340
    static let maximumWidth: CGFloat = 400

    @Environment(UserConfig.self) private var userConfig
    @Binding var selectedTab: VideoInspectorTab
    @State private var speedInputText = ""
    @State private var subtitleTimingInputText = ""
    @State private var isShowingSubtitleBrowser = false

    let state: VideoInspectorState
    let playlist: VideoPlaylist
    let currentURL: URL?
    let currentTitle: String?
    let primarySubtitleName: String?
    let isPrimarySubtitleActive: Bool
    let remoteSubtitleOptions: [RemoteVideoSubtitleOption]
    let selectedRemoteSubtitleID: String?
    let selectedJimakuSubtitleID: String?
    let selectedJimakuSubtitleName: String?
    let selectedAJATTSubtitleID: String?
    let selectedAJATTSubtitleName: String?
    let remoteQualityOptions: [RemoteVideoQualityOption]
    let selectedRemoteQualityID: String?

    var onSelectEpisode: (URL) -> Void
    var onSetSpeed: (Double) -> Void
    var onSetSubtitleDelay: (TimeInterval) -> Void
    var onSetAudioDelay: (TimeInterval) -> Void
    var onSetLoopMode: (VideoLoopMode) -> Void
    var onSetABLoopStart: () -> Void
    var onSetABLoopEnd: () -> Void
    var onClearABLoop: () -> Void
    var onSetAspectRatio: (VideoAspectRatio) -> Void
    var onRotateClockwise: () -> Void
    var onSetVideoShaderPreset: (VideoShaderPreset) -> Void
    var onSelectTrack: (VideoTrackType, Int?) -> Void
    var onSelectRemoteSubtitle: (RemoteVideoSubtitleOption) -> Void
    var onSelectJimakuSubtitle: (JimakuSubtitleFile) -> Void
    var onSelectAJATTSubtitle: (AJATTSubtitleFile) -> Void
    var onSelectOpenSubtitles: (RemoteVideoSubtitleOption) -> Void
    var onSelectExternalSubtitle: () -> Void
    var onSelectRemoteQuality: (RemoteVideoQualityOption) -> Void
    var onOpenSubtitle: () -> Void
    var onClearPrimarySubtitle: () -> Void
    var onOpenTranscript: () -> Void
    var onClose: () -> Void

    private let speedChoices = VideoPlaybackSpeed.presetChoices
    private let speedRows = [
        [0.25, 0.5, 1, 1.5],
        [2, 3, 4, 5],
    ]
    private static let subtitleTimingLargeStepMilliseconds = 1_000
    private static let subtitleTimingSmallStepMilliseconds = 50
    private static let audioTimingStep: TimeInterval = 0.5
    private static let cornerRadius: CGFloat = 26

    var body: some View {
        VStack(spacing: 0) {
            header

            VideoInspectorTabBar(selection: $selectedTab)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)

            Rectangle()
                .fill(.separator)
                .frame(height: 0.5)
                .opacity(0.6)

            ScrollView {
                tabContent
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .padding(.bottom, 18)
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
        }
        .frame(minWidth: Self.minimumWidth, idealWidth: Self.idealWidth, maxWidth: Self.maximumWidth)
        .modifier(VideoInspectorGlassSurface(cornerRadius: Self.cornerRadius))
        .onAppear {
            synchronizeSpeedInput()
            synchronizeSubtitleTimingInput()
        }
        .onChange(of: state.speed) { _, _ in
            synchronizeSpeedInput()
        }
        .onChange(of: state.subtitleDelay) { _, _ in
            synchronizeSubtitleTimingInput()
        }
        .sheet(isPresented: $isShowingSubtitleBrowser) {
            OnlineSubtitleBrowserView(
                suggestion: subtitleCatalogSuggestion,
                onSelectJimaku: onSelectJimakuSubtitle,
                onSelectAJATT: onSelectAJATTSubtitle,
                onSelectOpenSubtitles: onSelectOpenSubtitles
            )
        }
    }

    // MARK: Header

    /// Names what is playing instead of repeating the panel's own title.
    private var header: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(headerCaption)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .help(displayTitle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(VideoInspectorIconButtonStyle())
            .help("Close")
            .accessibilityLabel(Text("Close"))
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var displayTitle: String {
        if let currentTitle, !currentTitle.isEmpty {
            return currentTitle
        }
        return currentURL?.deletingPathExtension().lastPathComponent ?? String(localized: "Inspector")
    }

    private var currentEpisodeIndex: Int? {
        guard let currentURL else { return nil }
        let current = currentURL.standardizedFileURL
        return playlist.items.firstIndex { $0.standardizedFileURL == current }
    }

    private var headerCaption: String {
        let nowPlaying = String(localized: "Now Playing")
        guard playlist.items.count > 1, let index = currentEpisodeIndex else {
            return nowPlaying
        }
        return "\(nowPlaying) · \(index + 1) / \(playlist.items.count)"
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .episodes:
            episodesTab
        case .video:
            videoTab
        case .audio:
            audioTab
        case .subtitles:
            subtitlesTab
        }
    }

    // MARK: Episodes

    private var episodesTab: some View {
        inspectorSection("Episodes", accessory: {
            if !playlist.items.isEmpty {
                Text(playlist.items.count, format: .number)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }) {
            if playlist.items.isEmpty {
                emptyRow("No episodes", systemImage: "list.number")
            } else {
                ForEach(Array(playlist.items.enumerated()), id: \.element.standardizedFileURL) { index, url in
                    if index > 0 {
                        rowDivider
                    }
                    VideoInspectorEpisodeRow(
                        number: index + 1,
                        title: url.deletingPathExtension().lastPathComponent,
                        isCurrent: index == currentEpisodeIndex
                    ) {
                        onSelectEpisode(url)
                    }
                }
            }
        }
    }

    // MARK: Video

    private var videoTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            inspectorSection("Playback Speed", accessory: {
                Text(VideoPlaybackSpeed.label(state.speed))
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }) {
                VStack(spacing: 10) {
                    VStack(spacing: 6) {
                        ForEach(speedRows, id: \.self) { row in
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
                                    .buttonStyle(VideoInspectorChipButtonStyle(isSelected: isSpeedSelected(speed)))
                                }
                            }
                        }
                    }

                    HStack(spacing: 10) {
                        Image(systemName: "tortoise.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(
                            value: Binding<Double>(
                                get: { sliderSpeed },
                                set: { setSpeed($0) }
                            ),
                            in: VideoPlaybackSpeed.customInputLowerBound...VideoPlaybackSpeed.maximum,
                            step: VideoPlaybackSpeed.customStep
                        )
                        .controlSize(.small)
                        Image(systemName: "hare.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 2) {
                            TextField("Custom", text: $speedInputText)
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .frame(width: 36)
                                .onSubmit {
                                    commitSpeedInput()
                                }
                            Text(verbatim: "x")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .modifier(VideoInspectorFieldSurface())
                    }
                }
                .padding(12)
            }

            if !remoteQualityOptions.isEmpty {
                inspectorSection(
                    remoteQualityOptions.contains { $0.label != nil } ? "Streaming Quality" : "YouTube Quality") {
                    ForEach(Array(remoteQualityOptions.enumerated()), id: \.element.id) { index, option in
                        if index > 0 {
                            rowDivider
                        }
                        choiceRow(
                            title: option.label ?? "\(option.height)p",
                            detail: nil,
                            isSelected: option.id == selectedRemoteQualityID
                        ) {
                            onSelectRemoteQuality(option)
                        }
                    }
                }
            }

            inspectorSection("Picture") {
                labeledRow("Aspect Ratio", systemImage: "rectangle.inset.filled") {
                    NativeGlassMenuPicker(
                        selection: Binding<VideoAspectRatio>(
                            get: { state.aspectRatio },
                            set: { onSetAspectRatio($0) }
                        ),
                        values: VideoAspectRatio.allCases,
                        minWidth: 96
                    ) { aspectRatio in
                        Text(LocalizedStringKey(aspectRatio.title))
                    }
                }

                rowDivider

                labeledRow("Rotate Clockwise", systemImage: "rotate.right") {
                    Button {
                        onRotateClockwise()
                    } label: {
                        Image(systemName: "rotate.right")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(VideoInspectorIconButtonStyle())
                    .help("Rotate Clockwise")
                    .accessibilityLabel(Text("Rotate Clockwise"))
                }
            }

            trackSection(title: "Video Track", type: .video, allowsOff: false)

            inspectorSection("Loop") {
                toggleRow("Loop File", systemImage: "repeat", isOn: Binding<Bool>(
                    get: { state.loopMode == .file },
                    set: { onSetLoopMode($0 ? .file : .none) }
                ))

                rowDivider

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        rowLabel("A-B Loop", systemImage: "point.forward.to.point.capsulepath")
                        Spacer(minLength: 8)
                        if let abLoop = state.abLoop {
                            Text(verbatim: "\(VideoTimeFormatter.string(from: abLoop.start)) – \(VideoTimeFormatter.string(from: abLoop.end))")
                                .font(.caption.weight(.medium).monospacedDigit())
                                .foregroundStyle(Color.accentColor)
                        }
                    }

                    HStack(spacing: 6) {
                        Button("Set A Point", action: onSetABLoopStart)
                            .buttonStyle(VideoInspectorChipButtonStyle(isSelected: false))
                        Button("Set B Point", action: onSetABLoopEnd)
                            .buttonStyle(VideoInspectorChipButtonStyle(isSelected: false))
                        Button("Clear", action: onClearABLoop)
                            .buttonStyle(VideoInspectorChipButtonStyle(isSelected: false))
                            .disabled(state.abLoop == nil)
                    }
                    .font(.caption.weight(.semibold))
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }

            videoEnhancementSection

            pictureAdjustmentsSection
        }
    }

    private var videoEnhancementSection: some View {
        inspectorSection("Video Enhancement") {
            toggleRow("Hardware Decoding", systemImage: "cpu") {
                Toggle("Hardware Decoding", isOn: videoHardwareDecodingEnabled)
            }
            rowDivider
            toggleRow("Deinterlace", systemImage: "line.3.horizontal") {
                Toggle("Deinterlace", isOn: videoDeinterlacingEnabled)
            }
            rowDivider
            toggleRow("HDR", systemImage: "sun.max.trianglebadge.exclamationmark") {
                Toggle("HDR", isOn: videoHDREnhancementEnabled)
            }
            rowDivider

            VStack(alignment: .leading, spacing: 8) {
                rowLabel("Anime4K Upscaling", systemImage: "sparkles.tv")
                VideoAnime4KPresetControl(
                    minimumPickerWidth: 170,
                    onActivate: onSetVideoShaderPreset
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private var pictureAdjustmentsSection: some View {
        inspectorSection("Picture Adjustments", accessory: {
            if VideoEqualizerAdjustment.allCases.contains(where: { videoEqualizerBinding($0).wrappedValue != VideoEqualizerAdjustment.neutral }) {
                Button("Reset") {
                    for adjustment in VideoEqualizerAdjustment.allCases {
                        videoEqualizerBinding(adjustment).wrappedValue = VideoEqualizerAdjustment.neutral
                    }
                }
                .buttonStyle(VideoInspectorLinkButtonStyle())
            }
        }) {
            ForEach(Array(VideoEqualizerAdjustment.allCases.enumerated()), id: \.element) { index, adjustment in
                if index > 0 {
                    rowDivider
                }
                videoEqualizerSlider(
                    adjustment,
                    value: videoEqualizerBinding(adjustment)
                )
            }
        }
    }

    // MARK: Audio

    private var audioTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            trackSection(title: "Audio Track", type: .audio, allowsOff: true)

            inspectorSection("Audio Timing") {
                VideoInspectorStepperDisplay(
                    value: String(format: "%+.1f s", state.audioDelay),
                    isNeutral: state.audioDelay == 0,
                    decrements: [("-0.5 s", "minus", { onSetAudioDelay(max(state.audioDelay - Self.audioTimingStep, -30)) })],
                    increments: [("+0.5 s", "plus", { onSetAudioDelay(min(state.audioDelay + Self.audioTimingStep, 30)) })]
                )
                .padding(12)

                rowDivider

                HStack {
                    Spacer()
                    Button("Reset") {
                        onSetAudioDelay(0)
                    }
                    .buttonStyle(VideoInspectorLinkButtonStyle())
                    .disabled(state.audioDelay == 0)
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        }
    }

    // MARK: Subtitles

    private var subtitlesTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !remoteSubtitleOptions.isEmpty {
                inspectorSection("YouTube Subtitles") {
                    ForEach(Array(remoteSubtitleOptions.enumerated()), id: \.element.id) { index, option in
                        if index > 0 {
                            rowDivider
                        }
                        choiceRow(
                            title: remoteSubtitleTitle(option),
                            detail: option.language,
                            isSelected: option.id == selectedRemoteSubtitleID
                        ) {
                            onSelectRemoteSubtitle(option)
                        }
                    }
                }
            }

            subtitleSourcesSection

            subtitleTimingSection

            subtitleAppearanceSection

            subtitleMaskSection

            inspectorSection("Transcript") {
                Button {
                    onOpenTranscript()
                } label: {
                    HStack(spacing: 8) {
                        rowLabel("Open Transcript", systemImage: "text.alignleft")
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(VideoInspectorRowButtonStyle())
            }
        }
    }

    /// One list for every subtitle source: an external file loaded into mpv is
    /// a track, so the primary subtitle only gets its own row while it has no
    /// matching track (for example a catalog download still loading).
    private var subtitleSourcesSection: some View {
        let tracks = state.tracks.filter { $0.type == .subtitle }
        let primaryTrackID = VideoSubtitleTrackMatching.trackID(
            forFileNamed: primarySubtitleName,
            in: tracks
        )
        return inspectorSection("Subtitle Track") {
            choiceRow(
                title: String(localized: "Off"),
                detail: nil,
                isSelected: !tracks.contains(where: \.isSelected)
                    && !isPrimarySubtitleActive
                    && selectedRemoteSubtitleID == nil
            ) {
                onSelectTrack(.subtitle, nil)
            }

            if let primarySubtitleName, primaryTrackID == nil {
                rowDivider
                choiceRow(
                    title: primarySubtitleName,
                    detail: primarySubtitleSourceName,
                    isSelected: isPrimarySubtitleActive
                ) {
                    if !isPrimarySubtitleActive {
                        onSelectExternalSubtitle()
                    }
                }
            }

            ForEach(tracks) { track in
                rowDivider
                choiceRow(
                    title: track.displayName,
                    detail: subtitleTrackDetail(track, isPrimary: track.id == primaryTrackID),
                    isSelected: track.isSelected
                ) {
                    onSelectTrack(.subtitle, track.id)
                }
            }

            rowDivider

            HStack(spacing: 8) {
                Button {
                    isShowingSubtitleBrowser = true
                } label: {
                    Label("Find Subtitles", systemImage: "icloud.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(VideoInspectorChipButtonStyle(isSelected: false, isProminent: true))

                Button {
                    onOpenSubtitle()
                } label: {
                    Label("Open Subtitles", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                }
                .buttonStyle(VideoInspectorChipButtonStyle(isSelected: false))
            }
            .font(.callout.weight(.semibold))
            .padding(10)
        }
    }

    private func subtitleTrackDetail(_ track: VideoTrack, isPrimary: Bool) -> String? {
        guard track.externalFilename != nil else { return track.codec }
        let source = isPrimary ? primarySubtitleSourceName : String(localized: "External Subtitles")
        return [source, track.codec].compactMap { $0 }.joined(separator: " · ")
    }

    private var subtitleCatalogSuggestion: JimakuMediaSuggestion {
        JimakuMediaSuggestion(
            sourceIdentifier: currentURL?.absoluteString ?? currentTitle ?? "video",
            mediaTitle: currentTitle ?? currentURL?.deletingPathExtension().lastPathComponent ?? ""
        )
    }

    private var primarySubtitleSourceName: String {
        if selectedAJATTSubtitleName != nil {
            return "AJATT"
        } else if selectedJimakuSubtitleName != nil {
            return "Jimaku"
        } else {
            return String(localized: "Primary subtitle")
        }
    }

    private var subtitleTimingSection: some View {
        inspectorSection(
            "Subtitle Timing",
            footer: "Positive values delay subtitles; negative values show subtitles earlier."
        ) {
            VStack(spacing: 12) {
                VideoInspectorStepperDisplay(
                    value: subtitleTimingValueText,
                    isNeutral: subtitleTimingMilliseconds == 0,
                    decrements: [
                        ("Back 1000 ms", "chevron.left.2", {
                            let current = subtitleTimingMilliseconds
                            applySubtitleTimingMilliseconds(current - Self.subtitleTimingLargeStepMilliseconds)
                        }),
                        ("Back 50 ms", "chevron.left", {
                            let current = subtitleTimingMilliseconds
                            applySubtitleTimingMilliseconds(current - Self.subtitleTimingSmallStepMilliseconds)
                        }),
                    ],
                    increments: [
                        ("Forward 50 ms", "chevron.right", {
                            let current = subtitleTimingMilliseconds
                            applySubtitleTimingMilliseconds(current + Self.subtitleTimingSmallStepMilliseconds)
                        }),
                        ("Forward 1000 ms", "chevron.right.2", {
                            let current = subtitleTimingMilliseconds
                            applySubtitleTimingMilliseconds(current + Self.subtitleTimingLargeStepMilliseconds)
                        }),
                    ]
                )

                Slider(
                    value: Binding<Double>(
                        get: { Double(VideoSubtitleTiming.clampedSliderMilliseconds(subtitleTimingMilliseconds)) },
                        set: { applySubtitleTimingMilliseconds(Int($0.rounded())) }
                    ),
                    in: Double(VideoSubtitleTiming.sliderMilliseconds.lowerBound)...Double(VideoSubtitleTiming.sliderMilliseconds.upperBound),
                    step: Double(Self.subtitleTimingSmallStepMilliseconds)
                )
                .controlSize(.small)
            }
            .padding(12)

            rowDivider

            labeledRow("Offset (ms)", systemImage: "keyboard") {
                HStack(spacing: 6) {
                    TextField("Offset", text: $subtitleTimingInputText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .frame(width: 64)
                        .onSubmit {
                            commitSubtitleTimingInput()
                        }
                    Image(systemName: "keyboard")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .modifier(VideoInspectorFieldSurface())
            }
        }
    }

    private var subtitleAppearanceSection: some View {
        inspectorSection("Subtitle Appearance", accessory: {
            Button("Restore Defaults") {
                userConfig.resetVideoSubtitleAppearance()
            }
            .buttonStyle(VideoInspectorLinkButtonStyle())
        }) {
            toggleRow("Respect ASS subtitle styles", systemImage: "textformat.alt", isOn: Binding(
                get: { userConfig.videoRespectASSStyle },
                set: { userConfig.videoRespectASSStyle = $0 }
            ))

            rowDivider

            labeledRow("Subtitle Font", systemImage: "textformat") {
                NativeGlassMenuPicker(
                    selection: subtitleFontFamily,
                    values: [""] + Self.subtitleFontFamilies,
                    minWidth: 130
                ) { family in
                    if family.isEmpty {
                        Text("System Default")
                    } else {
                        Text(verbatim: family)
                    }
                }
                .frame(maxWidth: 170)
            }

            rowDivider

            sliderRow(
                "Subtitle Size",
                systemImage: "textformat.size",
                value: "\(Int(userConfig.videoSubtitleFontSize)) px",
                binding: subtitleFontSize,
                range: 12...72,
                step: 1
            )

            rowDivider

            labeledRow("Subtitle Weight", systemImage: "bold") {
                Stepper(
                    value: subtitleFontWeight,
                    in: 100...900,
                    step: 100
                ) {
                    Text(verbatim: "\(userConfig.videoSubtitleFontWeight)")
                        .font(.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }

            rowDivider

            labeledRow("Edge Style", systemImage: "character.textbox") {
                NativeGlassMenuPicker(
                    selection: subtitleEdgeStyle,
                    values: VideoSubtitleEdgeStyle.allCases,
                    minWidth: 110
                ) { style in
                    Text(style.localizedTitle)
                }
                .frame(maxWidth: 170)
            }

            rowDivider

            sliderRow(
                "Edge Strength",
                systemImage: "circle.dashed",
                value: "\(Int((userConfig.videoSubtitleEdgeStrength * 100).rounded()))%",
                binding: subtitleEdgeStrength,
                range: 0...1,
                step: 0.05
            )
            .disabled(userConfig.videoSubtitleEdgeStyle == .off)

            rowDivider

            toggleRow("No Background", systemImage: "rectangle.dashed", isOn: subtitleBackgroundDisabled)

            rowDivider

            sliderRow(
                "Background Opacity",
                systemImage: "rectangle.fill",
                value: "\(Int(userConfig.videoSubtitleBackgroundOpacity * 100))%",
                binding: subtitleBackgroundOpacity,
                range: 0...1,
                step: 0.05
            )
            .disabled(userConfig.videoSubtitleBackgroundDisabled)

            rowDivider

            subtitlePositionSlider(
                title: "Vertical Position",
                binding: subtitleVerticalPosition
            )

            rowDivider

            colorRow("Subtitle Color") {
                ColorPicker("Subtitle Color", selection: subtitleColor)
            }
            rowDivider
            colorRow("Lookup Highlight Color") {
                ColorPicker("Lookup Highlight Color", selection: subtitleLookupHighlightColor)
            }
            rowDivider
            colorRow("Lookup Highlight Text Color") {
                ColorPicker("Lookup Highlight Text Color", selection: subtitleLookupHighlightTextColor)
            }
        }
    }

    private var subtitleMaskSection: some View {
        inspectorSection("Subtitle Mask") {
            toggleRow("Mask subtitles until hover", systemImage: "eye.slash", isOn: subtitleMaskEnabled)

            rowDivider

            VStack(alignment: .leading, spacing: 12) {
                VideoInspectorSegmentedPicker(
                    selection: subtitleMaskMode,
                    values: VideoSubtitleMaskMode.allCases
                ) { mode in
                    Text(subtitleMaskModeTitle(mode))
                }

                if userConfig.videoSubtitleMaskMode == .blur {
                    sliderContent(
                        "Blur Radius",
                        systemImage: "drop.halffull",
                        value: "\(Int(userConfig.videoSubtitleMaskBlurRadius)) px",
                        binding: subtitleMaskBlurRadius,
                        range: 0...20,
                        step: 1
                    )
                } else {
                    sliderContent(
                        "Hidden Opacity",
                        systemImage: "circle.lefthalf.filled",
                        value: "\(Int(userConfig.videoSubtitleMaskHiddenOpacity * 100))%",
                        binding: subtitleMaskHiddenOpacity,
                        range: 0...1,
                        step: 0.05
                    )
                }
            }
            .padding(12)
            .disabled(!userConfig.videoSubtitleMaskEnabled)
        }
    }

    private func trackSection(
        title: LocalizedStringKey,
        type: VideoTrackType,
        allowsOff: Bool
    ) -> some View {
        let tracks = state.tracks.filter { $0.type == type }
        return inspectorSection(title) {
            if allowsOff {
                choiceRow(
                    title: String(localized: "Off"),
                    detail: nil,
                    isSelected: !tracks.contains(where: \.isSelected)
                ) {
                    onSelectTrack(type, nil)
                }
            }

            if tracks.isEmpty {
                if allowsOff {
                    rowDivider
                }
                emptyRow("No tracks", systemImage: type == .audio ? "waveform" : "film")
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    if allowsOff || index > 0 {
                        rowDivider
                    }
                    choiceRow(
                        title: track.displayName,
                        detail: track.codec,
                        isSelected: track.isSelected
                    ) {
                        onSelectTrack(type, track.id)
                    }
                }
            }
        }
    }

    // MARK: Bindings

    private var subtitleMaskEnabled: Binding<Bool> {
        Binding(
            get: { userConfig.videoSubtitleMaskEnabled },
            set: { userConfig.videoSubtitleMaskEnabled = $0 }
        )
    }

    private var subtitleFontFamily: Binding<String> {
        Binding(
            get: { userConfig.videoSubtitleFontFamily },
            set: { userConfig.videoSubtitleFontFamily = $0 }
        )
    }

    private var subtitleFontSize: Binding<Double> {
        Binding(
            get: { userConfig.videoSubtitleFontSize },
            set: { userConfig.videoSubtitleFontSize = $0 }
        )
    }

    private var subtitleFontWeight: Binding<Int> {
        Binding(
            get: { userConfig.videoSubtitleFontWeight },
            set: { userConfig.videoSubtitleFontWeight = $0 }
        )
    }

    private var subtitleEdgeStyle: Binding<VideoSubtitleEdgeStyle> {
        Binding(
            get: { userConfig.videoSubtitleEdgeStyle },
            set: { userConfig.videoSubtitleEdgeStyle = $0 }
        )
    }

    private var subtitleEdgeStrength: Binding<Double> {
        Binding(
            get: { userConfig.videoSubtitleEdgeStrength },
            set: { userConfig.videoSubtitleEdgeStrength = $0 }
        )
    }

    private var subtitleBackgroundOpacity: Binding<Double> {
        Binding(
            get: { userConfig.videoSubtitleBackgroundOpacity },
            set: { userConfig.videoSubtitleBackgroundOpacity = $0 }
        )
    }

    private var subtitleBackgroundDisabled: Binding<Bool> {
        Binding(
            get: { userConfig.videoSubtitleBackgroundDisabled },
            set: { userConfig.videoSubtitleBackgroundDisabled = $0 }
        )
    }

    private var subtitleVerticalPosition: Binding<Double> {
        Binding(
            get: { userConfig.videoSubtitleVerticalPosition },
            set: { userConfig.videoSubtitleVerticalPosition = $0 }
        )
    }

    private var subtitleColor: Binding<Color> {
        Binding(
            get: { userConfig.videoSubtitleColor },
            set: { userConfig.videoSubtitleColor = $0 }
        )
    }

    private var subtitleLookupHighlightColor: Binding<Color> {
        Binding(
            get: { userConfig.videoSubtitleLookupHighlightColor },
            set: { userConfig.videoSubtitleLookupHighlightColor = $0 }
        )
    }

    private var subtitleLookupHighlightTextColor: Binding<Color> {
        Binding(
            get: { userConfig.videoSubtitleLookupHighlightTextColor },
            set: { userConfig.videoSubtitleLookupHighlightTextColor = $0 }
        )
    }

    private var subtitleMaskMode: Binding<VideoSubtitleMaskMode> {
        Binding(
            get: { userConfig.videoSubtitleMaskMode },
            set: { userConfig.videoSubtitleMaskMode = $0 }
        )
    }

    private var subtitleMaskBlurRadius: Binding<Double> {
        Binding(
            get: { userConfig.videoSubtitleMaskBlurRadius },
            set: { userConfig.videoSubtitleMaskBlurRadius = $0 }
        )
    }

    private var subtitleMaskHiddenOpacity: Binding<Double> {
        Binding(
            get: { userConfig.videoSubtitleMaskHiddenOpacity },
            set: { userConfig.videoSubtitleMaskHiddenOpacity = $0 }
        )
    }

    private func subtitleMaskModeTitle(_ mode: VideoSubtitleMaskMode) -> String {
        switch mode {
        case .blur:
            String(localized: "Blur")
        case .transparent:
            String(localized: "Transparent")
        }
    }

    private var videoHardwareDecodingEnabled: Binding<Bool> {
        Binding(
            get: { userConfig.videoHardwareDecodingEnabled },
            set: { userConfig.videoHardwareDecodingEnabled = $0 }
        )
    }

    private var videoDeinterlacingEnabled: Binding<Bool> {
        Binding(
            get: { userConfig.videoDeinterlacingEnabled },
            set: { userConfig.videoDeinterlacingEnabled = $0 }
        )
    }

    private var videoHDREnhancementEnabled: Binding<Bool> {
        Binding(
            get: { userConfig.videoHDREnhancementEnabled },
            set: { userConfig.videoHDREnhancementEnabled = $0 }
        )
    }

    private func videoEqualizerBinding(
        _ adjustment: VideoEqualizerAdjustment
    ) -> Binding<Double> {
        Binding(
            get: {
                switch adjustment {
                case .brightness: userConfig.videoBrightness
                case .contrast: userConfig.videoContrast
                case .saturation: userConfig.videoSaturation
                case .gamma: userConfig.videoGamma
                case .hue: userConfig.videoHue
                }
            },
            set: { value in
                let normalized = VideoEqualizerAdjustment.normalized(value)
                switch adjustment {
                case .brightness: userConfig.videoBrightness = normalized
                case .contrast: userConfig.videoContrast = normalized
                case .saturation: userConfig.videoSaturation = normalized
                case .gamma: userConfig.videoGamma = normalized
                case .hue: userConfig.videoHue = normalized
                }
            }
        )
    }

    // MARK: Rows

    private func videoEqualizerSlider(
        _ adjustment: VideoEqualizerAdjustment,
        value: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                rowLabel(LocalizedStringKey(adjustment.title), systemImage: adjustment.systemName)
                Spacer(minLength: 8)
                if value.wrappedValue != VideoEqualizerAdjustment.neutral {
                    Button {
                        value.wrappedValue = VideoEqualizerAdjustment.neutral
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 20, height: 20)
                    }
                    .buttonStyle(VideoInspectorIconButtonStyle())
                    .help("Reset")
                    .accessibilityLabel(Text("Reset"))
                }
                Text("\(Int(value.wrappedValue.rounded()))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(value.wrappedValue == VideoEqualizerAdjustment.neutral ? Color.secondary : Color.accentColor)
                    .frame(minWidth: 32, alignment: .trailing)
            }

            Slider(
                value: value,
                in: VideoEqualizerAdjustment.minimum...VideoEqualizerAdjustment.maximum,
                step: 1
            )
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func sliderRow(
        _ title: LocalizedStringKey,
        systemImage: String,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        sliderContent(title, systemImage: systemImage, value: value, binding: binding, range: range, step: step)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
    }

    private func sliderContent(
        _ title: LocalizedStringKey,
        systemImage: String,
        value: String,
        binding: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                rowLabel(title, systemImage: systemImage)
                Spacer(minLength: 8)
                Text(value)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: binding, in: range, step: step)
                .controlSize(.small)
        }
    }

    private func subtitlePositionSlider(
        title: LocalizedStringKey,
        binding: Binding<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel(title, systemImage: "arrow.up.and.down")
            HStack(spacing: 8) {
                Image(systemName: "rectangle.topthird.inset.filled")
                    .foregroundStyle(.secondary)
                Slider(value: binding, in: VideoSubtitlePositionPolicy.range)
                    .labelsHidden()
                    .controlSize(.small)
                Image(systemName: "rectangle.bottomthird.inset.filled")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func colorRow<Picker: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder picker: () -> Picker
    ) -> some View {
        labeledRow(title, systemImage: "paintpalette") {
            picker()
                .labelsHidden()
        }
    }

    private func toggleRow(
        _ title: LocalizedStringKey,
        systemImage: String,
        isOn: Binding<Bool>
    ) -> some View {
        toggleRow(title, systemImage: systemImage) {
            Toggle(title, isOn: isOn)
        }
    }

    private func toggleRow<Control: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder toggle: () -> Control
    ) -> some View {
        labeledRow(title, systemImage: systemImage) {
            toggle()
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func labeledRow<Accessory: View>(
        _ title: LocalizedStringKey,
        systemImage: String,
        @ViewBuilder accessory: () -> Accessory
    ) -> some View {
        HStack(spacing: 10) {
            rowLabel(title, systemImage: systemImage)
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 40)
    }

    private func rowLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label {
            Text(title)
                .font(.callout)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
        }
    }

    private func choiceRow(
        title: String,
        detail: String?,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        VideoInspectorChoiceRow(
            title: title,
            detail: detail,
            isSelected: isSelected,
            action: action
        )
    }

    private func emptyRow(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 56)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 0.5)
            .padding(.leading, 12)
            .opacity(0.7)
    }

    private func inspectorSection<Content: View>(
        _ title: LocalizedStringKey,
        footer: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        inspectorSection(title, footer: footer, accessory: { EmptyView() }, content: content)
    }

    private func inspectorSection<Accessory: View, Content: View>(
        _ title: LocalizedStringKey,
        footer: LocalizedStringKey? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                accessory()
            }
            .padding(.horizontal, 4)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(VideoInspectorSectionGlassSurface(cornerRadius: 14))

            if let footer {
                Text(footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func remoteSubtitleTitle(_ option: RemoteVideoSubtitleOption) -> String {
        let language = Locale.current.localizedString(forLanguageCode: option.language)
            ?? option.name
        guard option.isAutomatic else { return language }
        return "\(language) · \(String(localized: "Auto-generated"))"
    }

    // MARK: Speed and timing

    private static func speedLabel(_ speed: Double) -> String {
        VideoPlaybackSpeed.label(speed)
    }

    private var selectedPresetSpeed: Double {
        let normalizedSpeed = VideoPlaybackSpeed.normalized(state.speed)
        return speedChoices.first { abs($0 - normalizedSpeed) < 0.001 } ?? normalizedSpeed
    }

    private func isSpeedSelected(_ speed: Double) -> Bool {
        abs(selectedPresetSpeed - VideoPlaybackSpeed.normalized(speed)) < 0.001
    }

    private var sliderSpeed: Double {
        min(
            max(VideoPlaybackSpeed.normalized(state.speed), VideoPlaybackSpeed.customInputLowerBound),
            VideoPlaybackSpeed.maximum
        )
    }

    private func setSpeed(_ speed: Double) {
        let normalizedSpeed = VideoPlaybackSpeed.normalized(speed)
        speedInputText = VideoPlaybackSpeed.label(normalizedSpeed, includesSuffix: false)
        onSetSpeed(normalizedSpeed)
    }

    private func synchronizeSpeedInput() {
        speedInputText = VideoPlaybackSpeed.label(state.speed, includesSuffix: false)
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

    private var subtitleTimingMilliseconds: Int {
        Self.clampedSubtitleTimingMilliseconds(
            Int((state.subtitleDelay * 1_000).rounded())
        )
    }

    private var subtitleTimingValueText: String {
        let milliseconds = subtitleTimingMilliseconds
        return "\(milliseconds >= 0 ? "+" : "")\(milliseconds) ms"
    }

    private func applySubtitleTimingMilliseconds(_ milliseconds: Int) {
        let clampedMilliseconds = Self.clampedSubtitleTimingMilliseconds(milliseconds)
        subtitleTimingInputText = "\(clampedMilliseconds)"
        onSetSubtitleDelay(TimeInterval(clampedMilliseconds) / 1_000)
    }

    private func synchronizeSubtitleTimingInput() {
        subtitleTimingInputText = "\(subtitleTimingMilliseconds)"
    }

    private func commitSubtitleTimingInput() {
        let normalizedText = subtitleTimingInputText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard let milliseconds = Int(normalizedText) else {
            synchronizeSubtitleTimingInput()
            return
        }
        applySubtitleTimingMilliseconds(milliseconds)
    }

    private static func clampedSubtitleTimingMilliseconds(_ milliseconds: Int) -> Int {
        VideoSubtitleTiming.clampedMilliseconds(milliseconds)
    }

    private static let subtitleFontFamilies: [String] = {
        NSFontManager.shared.availableFontFamilies.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }()
}

extension VideoInspectorView: Equatable {
    static func == (lhs: VideoInspectorView, rhs: VideoInspectorView) -> Bool {
        lhs.selectedTab == rhs.selectedTab
            && lhs.state == rhs.state
            && lhs.playlist == rhs.playlist
            && lhs.currentURL?.standardizedFileURL == rhs.currentURL?.standardizedFileURL
            && lhs.currentTitle == rhs.currentTitle
            && lhs.primarySubtitleName == rhs.primarySubtitleName
            && lhs.isPrimarySubtitleActive == rhs.isPrimarySubtitleActive
            && lhs.remoteSubtitleOptions == rhs.remoteSubtitleOptions
            && lhs.selectedRemoteSubtitleID == rhs.selectedRemoteSubtitleID
            && lhs.selectedJimakuSubtitleID == rhs.selectedJimakuSubtitleID
            && lhs.selectedJimakuSubtitleName == rhs.selectedJimakuSubtitleName
            && lhs.selectedAJATTSubtitleID == rhs.selectedAJATTSubtitleID
            && lhs.selectedAJATTSubtitleName == rhs.selectedAJATTSubtitleName
            && lhs.remoteQualityOptions == rhs.remoteQualityOptions
            && lhs.selectedRemoteQualityID == rhs.selectedRemoteQualityID
    }
}

// MARK: - Components

/// Icon-over-title tabs with a sliding selection pill.
private struct VideoInspectorTabBar: View {
    @Binding var selection: VideoInspectorTab
    @Namespace private var selectionNamespace
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(VideoInspectorTab.allCases) { tab in
                Button {
                    withAnimation(.snappy(duration: 0.22)) {
                        selection = tab
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemName)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(height: 17)
                        Text(tab.nativeSegmentTitle)
                            .font(.caption2.weight(.semibold))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .background {
                        if selection == tab {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(selectedFill)
                                .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(tab.title))
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(3)
        .background(containerFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var containerFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)
    }

    private var selectedFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.12) : Color.white.opacity(0.9)
    }
}

/// Compact two-to-three option switch with a sliding thumb.
private struct VideoInspectorSegmentedPicker<SelectionValue: Hashable, SegmentLabel: View>: View {
    @Binding var selection: SelectionValue
    let values: [SelectionValue]
    @ViewBuilder var label: (SelectionValue) -> SegmentLabel

    @Namespace private var thumbNamespace
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(values, id: \.self) { value in
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selection = value
                    }
                } label: {
                    label(value)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(selection == value ? .primary : .secondary)
                        .background {
                            if selection == value {
                                Capsule()
                                    .fill(thumbFill)
                                    .matchedGeometryEffect(id: "thumb", in: thumbNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(trackFill, in: Capsule())
    }

    private var trackFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06)
    }

    private var thumbFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.white
    }
}

/// Large centered value flanked by step buttons, shared by audio and
/// subtitle timing.
private struct VideoInspectorStepperDisplay: View {
    typealias Step = (help: LocalizedStringKey, systemImage: String, action: () -> Void)

    let value: String
    let isNeutral: Bool
    let decrements: [Step]
    let increments: [Step]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(decrements.enumerated()), id: \.offset) { _, step in
                stepButton(step)
            }

            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(isNeutral ? Color.primary : Color.accentColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity)
                .contentTransition(.numericText())

            ForEach(Array(increments.enumerated()), id: \.offset) { _, step in
                stepButton(step)
            }
        }
    }

    private func stepButton(_ step: Step) -> some View {
        Button(action: step.action) {
            Image(systemName: step.systemImage)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(VideoInspectorIconButtonStyle(isFilled: true))
        .help(step.help)
        .accessibilityLabel(Text(step.help))
    }
}

private struct VideoInspectorChoiceRow: View {
    let title: String
    let detail: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(isSelected ? .semibold : .regular))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(VideoInspectorRowButtonStyle())
        .help(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct VideoInspectorEpisodeRow: View {
    let number: Int
    let title: String
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(number, format: .number)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                    .frame(minWidth: 26, minHeight: 22)
                    .background(
                        isCurrent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )

                Text(title)
                    .font(.callout.weight(isCurrent ? .semibold : .regular))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .accessibilityLabel(Text("Now Playing"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(VideoInspectorRowButtonStyle())
        .help(title)
    }
}

private struct VideoInspectorRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        VideoInspectorHoverHighlight(isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

private struct VideoInspectorHoverHighlight<Content: View>: View {
    let isPressed: Bool
    @ViewBuilder let content: () -> Content

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        content()
            .opacity(isEnabled ? 1 : 0.45)
            .background {
                Rectangle()
                    .fill(Color.primary.opacity(isPressed ? 0.12 : (isHovered && isEnabled ? 0.06 : 0)))
            }
            .onHover { isHovered = $0 }
    }
}

/// Small pill buttons for presets and inline actions inside a group.
private struct VideoInspectorChipButtonStyle: ButtonStyle {
    let isSelected: Bool
    var isProminent = false

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .frame(minHeight: 24)
            .foregroundStyle(foreground)
            .background(fill(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
    }

    private var foreground: Color {
        if isSelected {
            return .white
        }
        return isProminent ? .accentColor : .primary
    }

    private func fill(isPressed: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(isPressed ? 0.8 : 1)
        }
        if isProminent {
            return Color.accentColor.opacity(isPressed ? 0.26 : 0.16)
        }
        let base = colorScheme == .dark ? 0.08 : 0.06
        return Color.primary.opacity(isPressed ? base + 0.08 : base)
    }
}

private struct VideoInspectorLinkButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.accentColor : Color.secondary)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

private struct VideoInspectorIconButtonStyle: ButtonStyle {
    var isFilled = false

    func makeBody(configuration: Configuration) -> some View {
        VideoInspectorIconButtonBody(
            configuration: configuration,
            isFilled: isFilled
        )
    }
}

private struct VideoInspectorIconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let isFilled: Bool

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            .background(Circle().fill(fill))
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.snappy(duration: 0.14), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }

    private var fill: Color {
        let resting = isFilled ? (colorScheme == .dark ? 0.09 : 0.07) : 0
        if configuration.isPressed {
            return Color.primary.opacity(resting + 0.12)
        }
        if isHovered && isEnabled {
            return Color.primary.opacity(resting + 0.07)
        }
        return Color.primary.opacity(resting)
    }
}

private struct VideoInspectorGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        GlassEffectContainer {
            content
                .background(legibilityFill, in: .rect(cornerRadius: cornerRadius))
                .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        }
    }

    /// The panel floats over saturated video frames; a neutral wash keeps its text readable.
    private var legibilityFill: Color {
        colorScheme == .dark ? Color.black.opacity(0.66) : Color.white.opacity(0.76)
    }
}

/// Grouped-list container: one flat fill per group, rows separated by inset hairlines.
private struct VideoInspectorSectionGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background(sectionFill, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(sectionStroke, lineWidth: 0.5)
            }
    }

    private var sectionFill: Color {
        colorScheme == .dark ? Color.white.opacity(0.065) : Color.white.opacity(0.7)
    }

    private var sectionStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }
}

private struct VideoInspectorFieldSurface: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)

        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(colorScheme == .dark ? Color.black.opacity(0.25) : Color.black.opacity(0.05), in: shape)
            .overlay {
                shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5)
            }
    }
}
