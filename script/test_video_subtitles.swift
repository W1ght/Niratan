// test-sources: Models/Subtitle.swift Features/Video/Subtitles/SubtitleCueStore.swift Features/Video/Subtitles/SubtitleOverlayRowHeightMeasurer.swift Features/Video/Subtitles/SubtitleParser.swift Features/Video/Subtitles/VideoSubtitleEdgeStyle.swift Features/Video/Subtitles/EmbeddedSubtitlePayloadParser.swift
import Foundation
#if canImport(AppKit)
import AppKit
#endif

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func expectFast(
    _ label: String,
    maxSeconds: TimeInterval,
    operation: () -> Void
) {
    let start = Date()
    operation()
    let elapsed = Date().timeIntervalSince(start)
    expect(
        elapsed <= maxSeconds,
        "\(label) should complete in \(maxSeconds)s, got \(String(format: "%.3f", elapsed))s"
    )
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfter: Int
    private var checks = 0

    init(cancelAfter: Int) {
        self.cancelAfter = cancelAfter
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks >= cancelAfter
    }

    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }
}

@main
private enum VideoSubtitleTests {
static func main() throws {
let srt = """
2
00:00:03,500 --> 00:00:05,000
二行目
です

1
00:00:01,000 --> 00:00:02,250
最初です
"""

let srtDocument = try SubtitleParser.parse(
    data: Data(srt.utf8),
    sourceURL: URL(fileURLWithPath: "/tmp/sample.srt")
)
expect(srtDocument.format == .srt, "SRT format should be detected")
expect(srtDocument.cues.count == 2, "SRT should parse two cues")
expect(srtDocument.cues[0].text == "最初です", "cues should be sorted by start time")
expect(srtDocument.cues[1].text == "二行目\nです", "multiline subtitle text should be preserved")
expect(srtDocument.cues[0].endTime == 2.25, "SRT milliseconds should be parsed")

#if canImport(AppKit)
let wrappedSubtitleText = "これはかなり長い字幕で、大きいフォントサイズでは自然に二行以上へ折り返される必要があります"
let wrappedEdgeRecipe = VideoSubtitleEdgeRecipe.make(
    style: .highContrast,
    strength: 0.5,
    fontSize: 43
)
let measuredLargeSubtitleHeight = SubtitleOverlayRowHeightMeasurer.height(
    for: wrappedSubtitleText,
    availableWidth: 360,
    fontFamily: "",
    fontSize: 43,
    fontWeight: 700,
    edgeAllowance: wrappedEdgeRecipe.layoutAllowance
)
let legacySingleLineEstimate = CGFloat(43 + 10)
expect(
    measuredLargeSubtitleHeight > legacySingleLineEstimate * 1.5,
    "large soft-wrapped subtitles should measure enough height for generated visual lines"
)
#endif

let vtt = """
WEBVTT

intro
00:00.500 --> 00:02.000 position:50%
こんにちは

00:01.500 --> 00:03.000
重なります
"""

let vttDocument = try SubtitleParser.parse(
    data: Data(vtt.utf8),
    sourceURL: URL(fileURLWithPath: "/tmp/sample.vtt")
)
expect(vttDocument.format == .webVTT, "WebVTT format should be detected")
expect(vttDocument.cues.count == 2, "WebVTT should parse two cues")

let youtubeKaraokeVTT = #"""
WEBVTT

00:04:49.000 --> 00:04:54.000 align:start position:0%
駅前<00:04:50.840><c>に</c><00:04:51.039><c>日高屋</c><00:04:51.560><c>以外</c><00:04:52.039><c>やっ</c><00:04:52.240><c>て</c><00:04:52.360><c>ない</c><00:04:52.600><c>みたい</c><00:04:52.880><c>な</c><00:04:53.120><c>状況</c>

00:04:54.000 --> 00:04:56.000
<v Speaker><b>Tea &amp; coffee</b></v>
"""#
let youtubeKaraokeDocument = try SubtitleParser.parse(
    data: Data(youtubeKaraokeVTT.utf8),
    sourceURL: URL(fileURLWithPath: "/tmp/youtube-karaoke.vtt")
)
expect(
    youtubeKaraokeDocument.cues[0].text == "駅前に日高屋以外やってないみたいな状況",
    "YouTube WebVTT word timestamps and class tags should not render as subtitle text"
)
expect(
    youtubeKaraokeDocument.cues[1].text == "Tea & coffee",
    "WebVTT voice/style tags should be removed while entities remain readable"
)

let ass = #"""
[Script Info]
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour
Style: Default,Arial,20,&H00FFFFFF

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Comment: 0,0:00:00.00,0:00:01.00,Default,,0,0,0,,comment should be ignored
Dialogue: 0,0:00:01.23,0:00:03.45,Default,,0,0,0,,{\an8}こんにちは\N世界, with comma
Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,{\\pos(1,2)}次{\\i1}です
"""#

let assDocument = try SubtitleParser.parse(
    data: Data(ass.utf8),
    sourceURL: URL(fileURLWithPath: "/tmp/sample.ass")
)
expect(assDocument.format.rawValue == "ass", "ASS format should be detected")
expect(assDocument.cues.count == 2, "ASS should parse dialogue events")
expect(assDocument.cues[0].startTime == 1.23, "ASS centiseconds should be parsed")
expect(assDocument.cues[0].text == "こんにちは\n世界, with comma", "ASS override tags should be stripped and text commas preserved")
expect(assDocument.cues[1].text == "次です", "ASS inline override tags should be stripped")
expect(
    assDocument.assRenderPlan?.primaryCueIDs.isEmpty == true,
    "top-aligned and explicitly positioned ASS events should remain libass-owned"
)

let invalidTimestampASS = #"""
[Script Info]
ScriptType: v4.00+

[V4+ Styles]
Format: Name, Fontname, Fontsize, Alignment
Style: Default,Arial,20,2

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Valid before
Dialogue: 0,0:nan,0:00:03.00,Default,,0,0,0,,Invalid NaN
Dialogue: 0,0:00:03.00,0:inf,Default,,0,0,0,,Invalid infinity
Dialogue: 0,10000000000000000:00:00.00,10000000000000000:00:01.00,Default,,0,0,0,,Invalid overflow
Dialogue: 0,-1:00:00.00,0:00:04.00,Default,,0,0,0,,Invalid negative
Dialogue: 0,0:00:04.00,0:00:05.00,Default,,0,0,0,,Valid after
"""#
let invalidTimestampDocument = try SubtitleParser.parse(
    data: Data(invalidTimestampASS.utf8),
    sourceURL: URL(fileURLWithPath: "/tmp/invalid-timestamps.ass")
)
expect(
    invalidTimestampDocument.cues.map(\.text) == ["Valid before", "Valid after"],
    "non-finite, negative, and integer-overflowing ASS timestamps should be skipped"
)
expect(
    invalidTimestampDocument.cues.allSatisfy {
        $0.startTime.isFinite && $0.endTime.isFinite
    },
    "parsed subtitle cues should always retain finite timestamps"
)

let cancellableSRT = (0..<200).map { index in
    let minute = index / 60
    let second = index % 60
    return """
    \(index + 1)
    00:\(String(format: "%02d", minute)):\(String(format: "%02d", second)),000 --> 00:\(String(format: "%02d", minute)):\(String(format: "%02d", second)),900
    cancellable cue \(index)
    """
}.joined(separator: "\n\n")
let srtCancellation = CancellationProbe(cancelAfter: 24)
var didCancelSRTParsing = false
do {
    _ = try SubtitleParser.parse(
        data: Data(cancellableSRT.utf8),
        sourceURL: URL(fileURLWithPath: "/tmp/cancellable.srt"),
        isCancelled: { srtCancellation.isCancelled() }
    )
} catch is CancellationError {
    didCancelSRTParsing = true
} catch {
    fputs("FAIL: cancellable SRT parsing threw \(error)\n", stderr)
    exit(1)
}
expect(
    didCancelSRTParsing && srtCancellation.checkCount == 24,
    "SRT parsing should observe cancellation from inside the block loop"
)

let cancellableASSDialogue = (0..<200).map { index in
    let minute = index / 60
    let second = index % 60
    return "Dialogue: 0,0:\(String(format: "%02d", minute)):\(String(format: "%02d", second)).00,0:\(String(format: "%02d", minute)):\(String(format: "%02d", second)).90,Default,,0,0,0,,cancellable cue \(index)"
}.joined(separator: "\n")
let cancellableASS = """
[Script Info]
ScriptType: v4.00+
[V4+ Styles]
Format: Name, Fontname, Fontsize, Alignment
Style: Default,Arial,20,2
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
\(cancellableASSDialogue)
"""
let assCancellation = CancellationProbe(cancelAfter: 32)
var didCancelASSParsing = false
do {
    _ = try SubtitleParser.parse(
        data: Data(cancellableASS.utf8),
        sourceURL: URL(fileURLWithPath: "/tmp/cancellable.ass"),
        isCancelled: { assCancellation.isCancelled() }
    )
} catch is CancellationError {
    didCancelASSParsing = true
} catch {
    fputs("FAIL: cancellable ASS parsing threw \(error)\n", stderr)
    exit(1)
}
expect(
    didCancelASSParsing && assCancellation.checkCount == 32,
    "ASS parsing should observe cancellation from inside the event line loop"
)

let hybridASS = #"""
[Script Info]
Title: Hybrid ownership fixture
ScriptType: v4.00+

[V4+ Styles]
Format: Alignment, Name, Fontname, Fontsize, PrimaryColour
Style: 2,Bottom,Arial,42,&H00FFFFFF
Style: 8,Top,Arial,28,&H00FFFFFF
Style: 2,BottomFX,Arial,42,&H00FFFFFF
Style: 2,ED-JP,Arial,36,&H00FFFFFF

[Fonts]
fontname: fixture.ttf
!!binary-font-payload!!

[Events]
Format: Start, Layer, End, Name, Style, MarginV, MarginL, MarginR, Effect, Text
Comment: 0:00:00.00,0,0:00:01.00,,Bottom,0,0,0,,metadata stays intact
Dialogue: 0:00:01.00,0,0:00:03.00,JP,Bottom,24,10,20,,主台詞
Dialogue: 0:00:01.00,0,0:00:03.00,EN,Bottom,24,10,20,,Main dialogue
Dialogue: 0:00:03.00,0,0:00:04.00,,Top,0,0,0,,Top lyrics
Dialogue: 0:00:04.00,0,0:00:05.00,,Bottom,0,0,0,,{\an8}Inline top
Dialogue: 0:00:05.00,0,0:00:06.00,,Bottom,0,0,0,,{\pos(100,200)}Positioned
Dialogue: 0:00:06.00,0,0:00:07.00,,Bottom,0,0,0,,{\move(0,0,100,100)}Moving
Dialogue: 0:00:07.00,0,0:00:08.00,,Bottom,0,0,0,,{\org(10,10)}Origin
Dialogue: 0:00:08.00,0,0:00:09.00,,Bottom,0,0,0,,{\clip(0,0,100,100)}Clipped
Dialogue: 0:00:09.00,0,0:00:10.00,,Bottom,0,0,0,,{\p1}m 0 0 l 10 0 10 10{\p0}
Dialogue: 0:00:10.00,0,0:00:11.00,,Bottom,0,0,0,,{\kf20}Karaoke
Dialogue: 0:00:11.00,0,0:00:12.00,,Bottom,0,0,0,,{\t(0,500,\fscx120)}Animated geometry
Dialogue: 0:00:12.00,0,0:00:13.00,,Bottom,0,0,0,,{\t(0,500,\1c&H0000FF&)}Colour animation
Dialogue: 0:00:13.00,1,0:00:14.00,,Bottom,0,0,0,,Layered duplicate
Dialogue: 0:00:13.00,4,0:00:14.00,,Bottom,0,0,0,,{\bord4}Layered duplicate
Dialogue: 0:00:14.00,0,0:00:15.00,,Bottom,0,0,0,,{\an8\r}Reset remains top
Dialogue: 0:00:15.00,0,0:00:16.00,,Bottom,0,0,0,,{\an8\an2}First alignment wins
Dialogue: 0:00:16.00,0,0:00:17.00,,ED-JP,0,0,0,,Ending lyrics
Dialogue: 0:00:17.00,0,0:00:18.00,,Bottom,0,0,0,,{\fad(200,200)}Faded lyrics
Dialogue: 0:00:18.00,0,0:00:19.00,,Bottom,0,0,0,,Same-layer effect
Dialogue: 0:00:18.00,0,0:00:19.00,,BottomFX,0,0,0,,{\blur3}Same-layer effect
"""#
let hybridDocument = try SubtitleParser.parse(
    data: Data(hybridASS.utf8),
    sourceURL: URL(fileURLWithPath: "/tmp/hybrid.ass")
)
guard let hybridPlan = hybridDocument.assRenderPlan else {
    fputs("FAIL: ASS should produce a render plan\n", stderr)
    exit(1)
}
expect(
    Set(hybridPlan.primaryEvents.map(\.plainText)) == ["主台詞", "Main dialogue"],
    "only ordinary overlapping bilingual bottom dialogue should remain primary"
)
expect(
    hybridPlan.events.first(where: { $0.plainText == "主台詞" })?.name == "JP"
        && hybridPlan.events.first(where: { $0.plainText == "主台詞" })?.marginLeft == 10
        && hybridPlan.events.first(where: { $0.plainText == "主台詞" })?.marginRight == 20
        && hybridPlan.events.first(where: { $0.plainText == "主台詞" })?.marginVertical == 24,
    "ASS event metadata should retain reordered Name and Margin fields"
)
expect(
    hybridPlan.events.first(where: { $0.plainText == "Inline top" })?.styleAlignment == 2
        && hybridPlan.events.first(where: { $0.plainText == "Inline top" })?.effectiveAlignment == 8,
    "effective inline alignment should be retained independently from style alignment"
)
expect(
    hybridPlan.events.first(where: { $0.plainText == "Reset remains top" })?.effectiveAlignment == 8
        && hybridPlan.events.first(where: { $0.plainText == "First alignment wins" })?.effectiveAlignment == 8,
    "libass should keep the first event alignment across later resets or alignment tags"
)
expect(
    hybridPlan.events.first(where: { $0.plainText == "Positioned" })?.markers.contains(.position) == true
        && hybridPlan.events.first(where: { $0.plainText == "Moving" })?.markers.contains(.movement) == true
        && hybridPlan.events.first(where: { $0.plainText == "Origin" })?.markers.contains(.origin) == true
        && hybridPlan.events.first(where: { $0.plainText == "Clipped" })?.markers.contains(.clipping) == true
        && hybridPlan.events.first(where: { $0.plainText == "Karaoke" })?.markers.contains(.karaoke) == true
        && hybridPlan.events.first(where: { $0.plainText == "Animated geometry" })?.markers.contains(.geometricAnimation) == true
        && hybridPlan.events.first(where: { $0.plainText == "Ending lyrics" })?.markers.contains(.lyrics) == true
        && hybridPlan.events.first(where: { $0.plainText == "Faded lyrics" })?.markers.contains(.animation) == true,
    "ASS positioning, clipping, karaoke, and geometric-animation markers should survive parsing"
)
expect(
    hybridPlan.events.filter {
        $0.plainText == "Layered duplicate" || $0.plainText == "Same-layer effect"
    }.allSatisfy { !$0.isPrimaryDialogue },
    "same-time same-text effect copies should remain libass-owned even with the same layer"
)

let largeASSDialogueCount = 8_000
let largeASSDialogue = (0..<largeASSDialogueCount).map { index in
    let minutes = index / 60
    let seconds = index % 60
    let text = switch index % 5 {
    case 0:
        "{\\pos(100,200)}Positioned \(index)"
    case 1:
        "{\\move(0,0,100,100)}Moving \(index)"
    case 2:
        "{\\an8}Top aligned \(index)"
    case 3:
        "{\\t(0,500,\\fscx120)}Animated \(index)"
    default:
        "Ordinary dialogue \(index)"
    }
    return "Dialogue: 0,0:\(minutes):\(String(format: "%02d", seconds)).00,0:\(minutes):\(String(format: "%02d", seconds)).90,Bottom,,0,0,0,,\(text)"
}.joined(separator: "\n")
let largeASS = """
[Script Info]
ScriptType: v4.00+
[V4+ Styles]
Format: Name, Fontname, Fontsize, Alignment
Style: Bottom,Arial,20,2
[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
\(largeASSDialogue)
"""
var largeASSDocument: SubtitleDocument?
expectFast("large ASS classification", maxSeconds: 2.5) {
    largeASSDocument = try? SubtitleParser.parse(
        data: Data(largeASS.utf8),
        sourceURL: URL(fileURLWithPath: "/tmp/large-performance.ass")
    )
}
expect(
    largeASSDocument?.cues.count == largeASSDialogueCount
        && largeASSDocument?.assRenderPlan?.events.count == largeASSDialogueCount,
    "large ASS parsing should preserve every classified event"
)

guard let effectsData = hybridPlan.effectsOnlyData,
      let effectsASS = String(data: effectsData, encoding: .utf8) else {
    fputs("FAIL: hybrid ASS should produce an effects-only document\n", stderr)
    exit(1)
}
expect(
    effectsASS.contains("[Script Info]")
        && effectsASS.contains("[V4+ Styles]")
        && effectsASS.contains("[Fonts]")
        && effectsASS.contains("!!binary-font-payload!!")
        && effectsASS.contains("Comment: 0:00:00.00"),
    "effects-only ASS should preserve headers, styles, fonts, and non-rendered event ordering"
)
expect(
    !effectsASS.contains(",,主台詞")
        && !effectsASS.contains(",,Main dialogue")
        && effectsASS.contains("Top lyrics")
        && effectsASS.contains("Positioned")
        && effectsASS.contains("Colour animation")
        && effectsASS.contains("Ending lyrics")
        && effectsASS.contains("Faded lyrics")
        && effectsASS.contains("Layered duplicate")
        && effectsASS.contains("Same-layer effect"),
    "effects-only ASS should remove primary dialogue and retain every libass-owned event"
)

let hintedDocument = try SubtitleParser.parse(
    data: Data(hybridASS.utf8),
    sourceURL: URL(fileURLWithPath: "/tmp/embedded-video.mkv"),
    formatHint: .ass
)
expect(
    hintedDocument.format == .ass && hintedDocument.assRenderPlan != nil,
    "reconstructed embedded ASS should be parseable with an explicit format hint"
)

let ssaDocument = try SubtitleParser.parse(
    data: Data(ass.utf8),
    sourceURL: URL(fileURLWithPath: "/tmp/sample.ssa")
)
expect(ssaDocument.format.rawValue == "ssa", "SSA format should be detected")

let legacySSA = #"""
[Script Info]
ScriptType: v4.00
[V4 Styles]
Format: Name, Fontname, Fontsize, Alignment
Style: Default,Arial,20,2
[Events]
Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: Marked=0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Legacy bottom
Dialogue: Marked=0,0:00:02.00,0:00:03.00,Default,,0,0,0,,{\a6}Legacy top
Dialogue: Marked=0,0:00:03.00,0:00:04.00,Default,,0,0,0,,{\a8}Legacy compatible top
"""#
let legacySSADocument = try SubtitleParser.parse(
    data: Data(legacySSA.utf8),
    sourceURL: URL(fileURLWithPath: "/tmp/legacy.ssa")
)
expect(
    legacySSADocument.assRenderPlan?.primaryEvents.map(\.plainText) == ["Legacy bottom"],
    "SSA Marked fields and legacy/compatible alignment overrides should use the same ownership classifier"
)
expect(
    legacySSADocument.assRenderPlan?.events.first {
        $0.plainText == "Legacy compatible top"
    }?.effectiveAlignment == 7,
    "legacy SSA \\a4/\\a8 compatibility should match libass top-left alignment"
)

if let realASSPath = ProcessInfo.processInfo.environment["HOSHI_REAL_ASS_PATH"],
   !realASSPath.isEmpty {
    let realASSURL = URL(fileURLWithPath: realASSPath)
    let realASSDocument = try SubtitleParser.parse(
        data: Data(contentsOf: realASSURL),
        sourceURL: realASSURL
    )
    expect(realASSDocument.format.rawValue == "ass", "real ASS sample should be detected")
    expect(!realASSDocument.cues.isEmpty, "real ASS sample should parse cue text")
    expect(
        realASSDocument.cues.allSatisfy { !$0.text.contains("{") && !$0.text.contains("}") },
        "real ASS sample transcript text should not expose override tags"
    )
}

if let realLyricASSPath = ProcessInfo.processInfo.environment["HOSHI_REAL_LYRIC_ASS_PATH"],
   !realLyricASSPath.isEmpty {
    let realLyricASSURL = URL(fileURLWithPath: realLyricASSPath)
    let realLyricDocument = try SubtitleParser.parse(
        data: Data(contentsOf: realLyricASSURL),
        sourceURL: realLyricASSURL
    )
    let lyricEvents = realLyricDocument.assRenderPlan?.events.filter {
        $0.markers.contains(.lyrics)
    } ?? []
    expect(!lyricEvents.isEmpty, "real ASS lyric styles should be recognized")
    expect(
        lyricEvents.allSatisfy { !$0.isPrimaryDialogue },
        "real ASS lyric events should remain libass-owned"
    )
}

let store = SubtitleCueStore(document: vttDocument)
expect(store.cues(at: 0.25).isEmpty, "timeline gaps should return no cue")
expect(store.cues(at: 1.75).map(\.text) == ["こんにちは", "重なります"], "overlapping cues should both be returned")
expect(store.cues(at: 3.1).isEmpty, "expired cues should not remain active")
expect(
    store.cues(atPlaybackTime: 2.75, subtitleDelay: 1).map(\.text) == ["こんにちは", "重なります"],
    "positive subtitle delay should display cues later"
)
expect(
    store.cues(atPlaybackTime: 0.75, subtitleDelay: -1).map(\.text) == ["こんにちは", "重なります"],
    "negative subtitle delay should display cues earlier"
)

let navigationDocument = SubtitleDocument(
    sourceURL: URL(fileURLWithPath: "/tmp/navigation.srt"),
    format: .srt,
    cues: [
        SubtitleCue(id: "first", startTime: 0, endTime: 1.5, text: "first"),
        SubtitleCue(id: "second", startTime: 2, endTime: 4, text: "second"),
        SubtitleCue(id: "third", startTime: 5, endTime: 7, text: "third")
    ],
    warnings: []
)
let navigationStore = SubtitleCueStore(document: navigationDocument)
let gapSlice = navigationStore.slice(atPlaybackTime: 4.5, subtitleDelay: 0)
expect(
    gapSlice.showing.isEmpty
        && gapSlice.lastShown.map(\.text) == ["second"]
        && gapSlice.nextToShow.map(\.text) == ["third"],
    "subtitle slices should expose gap context for playback modes"
)
expect(
    navigationStore.delayAligningAdjacentCue(
        atPlaybackTime: 4.5,
        subtitleDelay: 0,
        direction: .previous
    ) == 2.5,
    "align-previous should place the closest ended cue at the current playback time"
)
expect(
    navigationStore.delayAligningAdjacentCue(
        atPlaybackTime: 4.5,
        subtitleDelay: 0,
        direction: .next
    ) == -0.5,
    "align-next should place the closest upcoming cue at the current playback time"
)
expect(
    navigationStore.delayAligningAdjacentCue(
        atPlaybackTime: 5,
        subtitleDelay: 0.5,
        direction: .previous
    ) == 3,
    "subtitle alignment should select adjacent cues using the existing delay"
)
expect(
    navigationStore.delayAligningAdjacentCue(
        atPlaybackTime: 3.25,
        subtitleDelay: 0,
        direction: .previous
    ) == 3.25,
    "align-previous should ignore the currently displaying cue and use the closest ended cue"
)
expect(
    navigationStore.delayAligningAdjacentCue(
        atPlaybackTime: 0.5,
        subtitleDelay: 0,
        direction: .previous
    ) == nil,
    "align-previous should be unavailable before any cue has ended"
)
let navigationTranscript = SubtitleTranscript(
    primary: navigationDocument,
    secondary: nil
)
expect(
    navigationTranscript.relativeRowIndex(
        atPlaybackTime: 3.25,
        subtitleDelay: 0,
        offset: -1
    ) == 0,
    "previous subtitle should select the preceding cue even after playback has entered the current cue"
)
expect(
    navigationTranscript.relativeRowIndex(
        atPlaybackTime: 3.75,
        subtitleDelay: 0.5,
        offset: -1
    ) == 0,
    "previous subtitle should resolve against subtitle-adjusted playback time"
)
expect(
    navigationTranscript.relativeRowIndex(
        atPlaybackTime: 3.25,
        subtitleDelay: 0,
        offset: 1
    ) == 2,
    "next subtitle should select the following cue"
)
expect(
    navigationTranscript.relativeRowIndex(
        atPlaybackTime: 0.5,
        subtitleDelay: 0,
        offset: -1
    ) == nil,
    "previous subtitle should not wrap before the first cue"
)

let largeDocument = SubtitleDocument(
    sourceURL: URL(fileURLWithPath: "/tmp/large.srt"),
    format: .srt,
    cues: (0..<60_000).map { index in
        let start = TimeInterval(index) * 0.5
        return SubtitleCue(
            id: "\(index)",
            startTime: start,
            endTime: start + 0.2,
            text: "cue \(index)"
        )
    } + [
        SubtitleCue(id: "long", startTime: 0, endTime: 40_000, text: "long cue")
    ],
    warnings: []
)
let largeStore = SubtitleCueStore(document: largeDocument)
expect(
    largeStore.cues(at: 29_999.05).contains { $0.id == "long" },
    "timeline queries should preserve long overlapping cues that started much earlier"
)
expectFast("large subtitle timeline queries", maxSeconds: 0.35) {
    for tick in 0..<1_500 {
        let time = 20_000 + TimeInterval(tick) * 0.01
        _ = largeStore.cues(at: time)
    }
}

let autoloadDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("hoshi-subtitle-autoload-\(UUID().uuidString)")
try FileManager.default.createDirectory(
    at: autoloadDirectory,
    withIntermediateDirectories: true
)
defer {
    try? FileManager.default.removeItem(at: autoloadDirectory)
}
let mediaURL = autoloadDirectory.appendingPathComponent("Episode 01.mkv")
let exactSRT = autoloadDirectory.appendingPathComponent("Episode 01.srt")
let exactVTT = autoloadDirectory.appendingPathComponent("Episode 01.vtt")
let exactASS = autoloadDirectory.appendingPathComponent("Episode 01.ass")
let exactSSA = autoloadDirectory.appendingPathComponent("Episode 01.ssa")
let languageSRT = autoloadDirectory.appendingPathComponent("Episode 02.ja.srt")
let languageASS = autoloadDirectory.appendingPathComponent("Episode 04.ja.ass")
let unrelatedSRT = autoloadDirectory.appendingPathComponent("Episode 03.srt")
try Data().write(to: mediaURL)
try Data().write(to: exactSRT)
try Data().write(to: exactVTT)
try Data().write(to: exactASS)
try Data().write(to: exactSSA)
try Data().write(to: languageSRT)
try Data().write(to: languageASS)
try Data().write(to: unrelatedSRT)
expect(
    VideoSubtitleAutoloadCandidate.bestCandidate(for: mediaURL) == exactSRT.standardizedFileURL,
    "subtitle autoload should prefer exact same-name SRT sidecars"
)
try FileManager.default.removeItem(at: exactSRT)
expect(
    VideoSubtitleAutoloadCandidate.bestCandidate(for: mediaURL) == exactVTT.standardizedFileURL,
    "subtitle autoload should fall back to exact same-name VTT sidecars"
)
try FileManager.default.removeItem(at: exactVTT)
expect(
    VideoSubtitleAutoloadCandidate.bestCandidate(for: mediaURL) == exactASS.standardizedFileURL,
    "subtitle autoload should fall back to exact same-name ASS sidecars"
)
try FileManager.default.removeItem(at: exactASS)
expect(
    VideoSubtitleAutoloadCandidate.bestCandidate(for: mediaURL) == exactSSA.standardizedFileURL,
    "subtitle autoload should fall back to exact same-name SSA sidecars"
)
expect(
    VideoSubtitleAutoloadCandidate.bestCandidate(
        for: autoloadDirectory.appendingPathComponent("Episode 02.mp4")
    ) == languageSRT.standardizedFileURL,
    "subtitle autoload should accept language-suffixed sidecars"
)
expect(
    VideoSubtitleAutoloadCandidate.bestCandidate(
        for: autoloadDirectory.appendingPathComponent("Episode 04.mp4")
    ) == languageASS.standardizedFileURL,
    "subtitle autoload should accept language-suffixed ASS sidecars"
)
expect(
    VideoSubtitleAutoloadCandidate.bestCandidate(
        for: autoloadDirectory.appendingPathComponent("No Match.mp4")
    ) == nil,
    "subtitle autoload should not pick unrelated sidecars"
)

do {
    _ = try SubtitleParser.parse(
        data: Data("not a subtitle".utf8),
        sourceURL: URL(fileURLWithPath: "/tmp/bad.srt")
    )
    fputs("FAIL: malformed subtitles should throw\n", stderr)
    exit(1)
} catch {
    // Expected.
}

let videoPlayerScreenPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Features/Video/VideoPlayerScreen.swift")
let videoPlayerScreen = try String(contentsOf: videoPlayerScreenPath, encoding: .utf8)
    + String(contentsOf: videoPlayerScreenPath.deletingLastPathComponent()
        .appendingPathComponent("VideoPlayerScreen+Subtitles.swift"), encoding: .utf8)
    + String(contentsOf: videoPlayerScreenPath.deletingLastPathComponent()
        .appendingPathComponent("VideoPlayerScreen+Chrome.swift"), encoding: .utf8)
    + String(contentsOf: videoPlayerScreenPath.deletingLastPathComponent()
        .appendingPathComponent("VideoPlayerScreen+OSD.swift"), encoding: .utf8)
    + String(contentsOf: videoPlayerScreenPath.deletingLastPathComponent()
        .appendingPathComponent("VideoPlayerScreen+Mining.swift"), encoding: .utf8)
    + String(contentsOf: videoPlayerScreenPath.deletingLastPathComponent()
        .appendingPathComponent("VideoPlayerScreen+Opening.swift"), encoding: .utf8)
    + String(contentsOf: videoPlayerScreenPath.deletingLastPathComponent()
        .appendingPathComponent("VideoPlayerScreen+Shortcuts.swift"), encoding: .utf8)
expect(
    videoPlayerScreen.contains("static let subtitleFileExtensions = [\"srt\", \"vtt\", \"ass\", \"ssa\"]"),
    "player subtitle importer should allow ASS and SSA files"
)

print("Video subtitle tests passed")
}
}
