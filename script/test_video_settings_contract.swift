import Foundation

private func require(
    _ source: String,
    contains text: String,
    _ message: String
) {
    guard source.contains(text) else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func requireCondition(
    _ condition: @autoclosure () -> Bool,
    _ message: String
) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func read(_ path: String) -> String {
    guard let value = try? String(contentsOfFile: path, encoding: .utf8) else {
        fputs("FAIL: could not read \(path)\n", stderr)
        exit(1)
    }
    return value
}

let userConfig = read("Core/UserConfig.swift")
let settings = read("Features/Settings/VideoSettingsView.swift")
let nativeSettings = read("NativeMac/NativeReuseViews.swift")
let player = read("Features/Video/VideoPlayerScreen.swift")
    + read("Features/Video/VideoPlayerScreen+Subtitles.swift")
    + read("Features/Video/VideoPlayerScreen+Chrome.swift")
    + read("Features/Video/VideoPlayerScreen+OSD.swift")
    + read("Features/Video/VideoPlayerScreen+Mining.swift")
    + read("Features/Video/VideoPlayerScreen+Opening.swift")
    + read("Features/Video/VideoPlayerScreen+Shortcuts.swift")
let inspector = read("Features/Video/VideoInspectorView.swift")
let subtitleOverlay = read("Features/Video/Subtitles/SubtitleOverlayView.swift")
let interactiveSubtitleText = read("Features/Video/Subtitles/InteractiveSubtitleTextView.swift")
let subtitleEdgeStyle = read("Features/Video/Subtitles/VideoSubtitleEdgeStyle.swift")
let localization = read("Localizable.xcstrings")
let shortcutActions = read("Features/Video/VideoShortcutActions.swift")
let project = read("Niratan.xcodeproj/project.pbxproj")

require(
    userConfig,
    contains: "var videoAutoPlayNext: Bool",
    "video auto-play preference should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoRememberPlaybackPosition: Bool",
    "video history preference should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleGapFastForwardEnabled: Bool",
    "video subtitle gap fast-forward preference should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleGapFastForwardSpeed: Double",
    "video subtitle gap fast-forward speed should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "defaults.object(forKey: \"videoSubtitleGapFastForwardEnabled\") as? Bool ?? false",
    "video subtitle gap fast-forward should default off"
)
require(
    userConfig,
    contains: "defaults.object(forKey: \"videoSubtitleGapFastForwardSpeed\") as? Double ?? 2.7",
    "video subtitle gap fast-forward speed should default to asbplayer's 2.7x rate"
)
require(
    userConfig,
    contains: "static func clampedVideoSubtitleGapFastForwardSpeed",
    "video subtitle gap fast-forward speed should share one clamp"
)
require(
    userConfig,
    contains: "var videoAutoPauseOnLookup: Bool",
    "video lookup auto-pause preference should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "defaults.object(forKey: \"videoAutoPauseOnLookup\") as? Bool ?? true",
    "video lookup auto-pause should default on to preserve existing lookup behavior"
)
require(
    userConfig,
    contains: "enum VideoControlBarLayout: String, CaseIterable, Codable",
    "video control bar layout should be a shared Codable user preference"
)
require(
    userConfig,
    contains: "var videoControlBarLayout: VideoControlBarLayout",
    "video control bar layout preference should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSeekInterval: Double",
    "video seek interval should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoMiningHistoryLimit: Int",
    "video mining history limit should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoHardwareDecodingEnabled: Bool",
    "video hardware decoding preference should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoDeinterlacingEnabled: Bool",
    "video deinterlacing preference should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoHDREnhancementEnabled: Bool",
    "video HDR enhancement preference should be centralized in UserConfig"
)
for equalizerPreference in [
    "videoBrightness",
    "videoContrast",
    "videoSaturation",
    "videoGamma",
    "videoHue",
] {
    require(
        userConfig,
        contains: "var \(equalizerPreference): Double",
        "video equalizer preference should be centralized in UserConfig: \(equalizerPreference)"
    )
}
require(
    userConfig,
    contains: "defaults.object(forKey: \"videoHardwareDecodingEnabled\") as? Bool ?? true",
    "hardware decoding should default on for lower CPU playback"
)
require(
    userConfig,
    contains: "defaults.object(forKey: \"videoHDREnhancementEnabled\") as? Bool ?? false",
    "HDR enhancement should default off because it changes tone mapping"
)
require(
    userConfig,
    contains: "static func clampedVideoEqualizerValue",
    "video equalizer preferences should share one finite -100...100 clamp"
)
require(
    userConfig,
    contains: "defaults.object(forKey: \"videoMiningHistoryLimit\") as? Int ?? 25",
    "video mining history should default to asbplayer's 25-item limit"
)
require(
    userConfig,
    contains: "var videoSubtitleFontFamily: String",
    "video subtitle font family should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleFontSize: Double",
    "video subtitle font size should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleFontWeight: Int",
    "video subtitle font weight should be centralized in UserConfig"
)
require(
    subtitleEdgeStyle,
    contains: "enum VideoSubtitleEdgeStyle: String, CaseIterable, Codable",
    "video subtitle edge style should be a stable Codable preference"
)
require(
    subtitleEdgeStyle,
    contains: "nonisolated struct VideoSubtitleEdgeRecipe: Equatable",
    "the glyph renderer recipe should remain usable from AppKit's nonisolated drawing callback"
)
require(
    project,
    contains: "Video/Subtitles/VideoSubtitleEdgeStyle.swift",
    "Xcode synchronized Features membership should include the subtitle edge value layer"
)
require(
    userConfig,
    contains: "var videoSubtitleEdgeStyle: VideoSubtitleEdgeStyle",
    "video subtitle edge style should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleEdgeStrength: Double",
    "video subtitle edge strength should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "VideoSubtitleEdgePreferenceResolver.resolve(",
    "UserConfig should resolve new defaults and legacy shadow migration through the tested resolver"
)
require(
    userConfig,
    contains: "legacyShadowRadius: defaults.object(forKey: \"videoSubtitleShadowRadius\") as? Double",
    "UserConfig should migrate an explicitly stored legacy shadow radius"
)
require(
    userConfig,
    contains: "videoSubtitleEdgeStyle = .highContrast",
    "Restore Defaults should restore the High Contrast style"
)
require(
    userConfig,
    contains: "videoSubtitleEdgeStrength = 0.5",
    "Restore Defaults should restore 50% edge strength"
)
require(
    userConfig,
    contains: "var videoSubtitleBackgroundOpacity: Double",
    "video subtitle background opacity should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleBackgroundDisabled: Bool",
    "video subtitle no-background preference should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleVerticalPosition: Double",
    "video subtitle vertical position should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleColor: Color",
    "video subtitle text color should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleLookupHighlightColor: Color",
    "video lookup highlight background color should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleLookupHighlightTextColor: Color",
    "video lookup highlight text color should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "Color(.sRGB, red: 181.0 / 255.0, green: 193.0 / 255.0, blue: 203.0 / 255.0, opacity: 62.0 / 255.0)",
    "video lookup highlight should default to the user's approved #B5C1CB3E color"
)
require(
    userConfig,
    contains: "Self.saveColor(videoSubtitleColor, key: \"videoSubtitleColor\")",
    "video subtitle text color should persist through the shared color codec"
)
require(
    userConfig,
    contains: "Self.saveColor(videoSubtitleLookupHighlightColor, key: \"videoSubtitleLookupHighlightColor\")",
    "video lookup highlight color should persist through the shared color codec"
)
require(
    userConfig,
    contains: "Self.saveColor(videoSubtitleLookupHighlightTextColor, key: \"videoSubtitleLookupHighlightTextColor\")",
    "video lookup highlight text color should persist through the shared color codec"
)
require(
    userConfig,
    contains: "defaults.string(forKey: \"videoSubtitleFontFamily\") ?? \"\"",
    "video subtitle font family should default to the asbplayer-style system font"
)
require(
    userConfig,
    contains: "defaults.object(forKey: \"videoSubtitleFontSize\") as? Double ?? 36",
    "video subtitle font size should default to asbplayer's 36 px default"
)
require(
    userConfig,
    contains: "defaults.object(forKey: \"videoSubtitleFontWeight\") as? Int ?? 700",
    "video subtitle font weight should default to a bold 700 weight"
)
require(
    userConfig,
    contains: "defaults.object(forKey: \"videoSubtitleBackgroundDisabled\") as? Bool ?? true",
    "video subtitle background should default to disabled for transparent overlay text"
)
require(
    userConfig,
    contains: "min(max(newValue, 12), 72)",
    "video subtitle font size should be clamped to a readable range"
)
require(
    userConfig,
    contains: "min(max(newValue, 100), 900)",
    "video subtitle font weight should be clamped to CSS-style 100...900"
)
require(
    subtitleEdgeStyle,
    contains: "guard let value, value.isFinite else { return 0.5 }",
    "video subtitle edge strength should reject non-finite values"
)
require(
    subtitleEdgeStyle,
    contains: "min(max(value, 0), 1)",
    "video subtitle edge strength should be clamped to 0...1"
)
require(
    userConfig,
    contains: "VideoSubtitlePositionPolicy.normalized(videoSubtitleVerticalPosition)",
    "video subtitle position assignment should normalize"
)
require(
    userConfig,
    contains: "forKey: \"videoSubtitleVerticalPositionFraction\"",
    "video subtitle position should use the new fraction key"
)
require(
    userConfig,
    contains: "forKey: \"videoSubtitleVerticalPositionFraction\"\n        ) as? Double",
    "video subtitle position should load the new fraction key"
)
require(
    userConfig,
    contains: "VideoSubtitlePositionPolicy.migratedLegacyPosition(",
    "video subtitle position should migrate the legacy key"
)
require(
    userConfig,
    contains: "defaults.object(forKey: \"videoSubtitleVerticalPosition\") as? Double",
    "subtitle position migration should read the legacy key"
)
require(
    userConfig,
    contains: "videoSubtitleVerticalPosition = VideoSubtitlePositionPolicy.defaultPosition",
    "appearance reset should restore the relative default"
)
requireCondition(
    !userConfig.contains("videoSubtitleVerticalPositionRange"),
    "fixed-point subtitle position range should be removed"
)
requireCondition(
    !userConfig.contains("clampedVideoSubtitleVerticalPosition"),
    "fixed-point subtitle position clamp should be removed"
)
require(
    userConfig,
    contains: "func resetVideoSubtitleAppearance()",
    "video subtitle appearance should expose a restore-defaults action"
)
require(
    userConfig,
    contains: "enum VideoSubtitleMaskMode: String, CaseIterable, Codable",
    "video subtitle mask mode should be a shared Codable user preference"
)
require(
    userConfig,
    contains: "var videoSubtitleMaskEnabled: Bool",
    "video subtitle mask enabled preference should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleMaskMode: VideoSubtitleMaskMode",
    "video subtitle mask mode preference should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleMaskBlurRadius: Double",
    "video subtitle blur radius preference should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "var videoSubtitleMaskHiddenOpacity: Double",
    "video subtitle transparent-mode opacity preference should be centralized in UserConfig"
)
require(
    userConfig,
    contains: "min(max(newValue, 0), 20)",
    "video subtitle blur radius should be clamped to 0...20"
)
require(
    userConfig,
    contains: "min(max(newValue, 0), 1)",
    "video subtitle hidden opacity should be clamped to 0...1"
)
requireCondition(
    !userConfig.contains("min(max(videoSubtitleMaskHiddenOpacity, 0), 1)"),
    "video subtitle hidden opacity observer should not read itself and recurse"
)
require(
    settings,
    contains: "\"Auto-Play Next Episode\"",
    "Video settings should expose auto-play next"
)
require(
    settings,
    contains: "\"Remember Playback State\"",
    "Video settings should expose playback-state history"
)
require(
    settings,
    contains: "\"Auto-pause on Lookup\"",
    "Video settings should expose lookup auto-pause"
)
require(
    settings,
    contains: "isOn: $userConfig.videoAutoPauseOnLookup",
    "Video settings should bind lookup auto-pause to UserConfig"
)
require(
    settings,
    contains: "\"Control Bar Layout\"",
    "Video settings should expose control bar layout"
)
require(
    settings,
    contains: "$userConfig.videoControlBarLayout",
    "Video settings should bind the control bar layout preference"
)
require(
    settings,
    contains: "VideoControlBarLayout.allCases",
    "Video settings should show all control bar layout choices"
)
require(
    settings,
    contains: "\"Floating\"",
    "Video settings should label the floating control layout"
)
require(
    settings,
    contains: "\"Compact Bottom\"",
    "Video settings should label the compact bottom control layout"
)
require(
    settings,
    contains: "\"Restores playback position, subtitles, speed, timing, and audio track for each video.\"",
    "Video settings should explain which per-video state is restored"
)
require(
    settings,
    contains: "\"Video Enhancement\"",
    "Video settings should expose hardware and color enhancement controls"
)
require(
    settings,
    contains: "$userConfig.videoHardwareDecodingEnabled",
    "Video settings should expose the hardware decoding toggle"
)
require(
    settings,
    contains: "$userConfig.videoDeinterlacingEnabled",
    "Video settings should expose the deinterlacing toggle"
)
require(
    settings,
    contains: "$userConfig.videoHDREnhancementEnabled",
    "Video settings should expose the HDR enhancement toggle"
)
for equalizerBinding in [
    "$userConfig.videoBrightness",
    "$userConfig.videoContrast",
    "$userConfig.videoSaturation",
    "$userConfig.videoGamma",
    "$userConfig.videoHue",
] {
    require(
        settings,
        contains: equalizerBinding,
        "Video settings should expose equalizer binding \(equalizerBinding)"
    )
}
require(
    settings,
    contains: "$userConfig.videoSeekInterval",
    "Video settings should expose the default seek interval"
)
require(
    settings,
    contains: "$userConfig.videoMiningHistoryLimit",
    "Video settings should expose the mining history storage limit"
)
require(
    settings,
    contains: "\"Subtitle Appearance\"",
    "Video settings should expose subtitle appearance controls"
)
require(
    settings,
    contains: "$userConfig.videoSubtitleFontFamily",
    "Video settings should expose the subtitle font picker"
)
require(
    settings,
    contains: "$userConfig.videoSubtitleFontSize",
    "Video settings should expose the subtitle size slider"
)
for subtitleAppearanceBinding in [
    "$userConfig.videoSubtitleFontWeight",
    "$userConfig.videoSubtitleEdgeStyle",
    "$userConfig.videoSubtitleEdgeStrength",
    "$userConfig.videoSubtitleBackgroundOpacity",
    "$userConfig.videoSubtitleBackgroundDisabled",
    "$userConfig.videoSubtitleVerticalPosition",
] {
    require(
        settings,
        contains: subtitleAppearanceBinding,
        "Video settings should expose subtitle appearance binding \(subtitleAppearanceBinding)"
    )
}
requireCondition(
    settings.contains("in: VideoSubtitlePositionPolicy.range")
        && settings.contains("rectangle.topthird.inset.filled")
        && settings.contains("rectangle.bottomthird.inset.filled")
        && !settings.contains(
            "value: \"\\(Int(userConfig.videoSubtitleVerticalPosition))\""
        ),
    "Video settings should expose an icon-ended relative slider without a number"
)
require(
    settings,
    contains: "userConfig.resetVideoSubtitleAppearance",
    "Video settings should expose restore defaults for subtitle appearance"
)
require(
    settings,
    contains: "ColorPicker(\"Subtitle Color\", selection: $userConfig.videoSubtitleColor",
    "Video settings should expose the subtitle text color picker"
)
require(
    settings,
    contains: "ColorPicker(\"Lookup Highlight Color\", selection: $userConfig.videoSubtitleLookupHighlightColor",
    "Video settings should expose the lookup highlight color picker"
)
require(
    settings,
    contains: "ColorPicker(\"Lookup Highlight Text Color\", selection: $userConfig.videoSubtitleLookupHighlightTextColor",
    "Video settings should expose the lookup highlight text color picker"
)
require(
    settings,
    contains: "\"Subtitle Mask\"",
    "Video settings should expose subtitle mask controls"
)
require(
    settings,
    contains: "$userConfig.videoSubtitleMaskEnabled",
    "Video settings should expose the subtitle mask toggle"
)
require(
    settings,
    contains: "$userConfig.videoSubtitleMaskMode",
    "Video settings should expose the subtitle mask mode"
)
require(
    settings,
    contains: "$userConfig.videoSubtitleMaskBlurRadius",
    "Video settings should expose the subtitle blur radius slider"
)
require(
    settings,
    contains: "$userConfig.videoSubtitleMaskHiddenOpacity",
    "Video settings should expose the subtitle hidden opacity slider"
)
for obsoleteShortcutUI in [
    "shortcutSummarySection",
    "shortcutSummaryGroup",
    "shortcutSummaryRow",
    "\"Playback Shortcuts\"",
    "\"Subtitle Shortcuts\"",
    "\"Audio Shortcuts\"",
    "\"Open Keyboard Shortcuts\"",
] {
    requireCondition(
        !settings.contains(obsoleteShortcutUI),
        "Video settings must not duplicate the unified shortcut UI: \(obsoleteShortcutUI)"
    )
}
require(
    inspector,
    contains: "\"Subtitle Appearance\"",
    "Video inspector should expose subtitle appearance controls in the Subtitles tab"
)
require(
    inspector,
    contains: "subtitleAppearanceSection",
    "Video inspector should keep subtitle appearance controls in a dedicated section"
)
require(
    inspector,
    contains: "subtitleFontFamily",
    "Video inspector should bind the subtitle font family setting"
)
require(
    inspector,
    contains: "subtitleFontSize",
    "Video inspector should bind the subtitle font size setting"
)
for subtitleInspectorBinding in [
    "subtitleFontWeight",
    "subtitleEdgeStyle",
    "subtitleEdgeStrength",
    "subtitleBackgroundOpacity",
    "subtitleBackgroundDisabled",
    "subtitleVerticalPosition",
] {
    require(
        inspector,
        contains: subtitleInspectorBinding,
        "Video inspector should bind subtitle appearance setting \(subtitleInspectorBinding)"
    )
}
require(
    settings,
    contains: "values: VideoSubtitleEdgeStyle.allCases",
    "Video settings should expose all four edge styles through one menu"
)
require(
    inspector,
    contains: "values: VideoSubtitleEdgeStyle.allCases",
    "Video Inspector should expose the same edge-style menu"
)
require(
    inspector,
    contains: "binding: subtitleEdgeStrength",
    "Video Inspector should expose the shared edge-strength slider"
)
requireCondition(
    !settings.contains("$userConfig.videoSubtitleShadowRadius")
        && !inspector.contains("subtitleShadowRadius"),
    "the legacy Shadow slider should no longer appear in either UI surface"
)
requireCondition(
    !settings.contains("Shadow Color")
        && !settings.contains("Outline Color")
        && !inspector.contains("Shadow Color")
        && !inspector.contains("Outline Color"),
    "compact subtitle edge controls should not expose advanced colors"
)
requireCondition(
    inspector.contains("subtitlePositionSlider(")
        && inspector.contains("in: VideoSubtitlePositionPolicy.range")
        && inspector.contains("rectangle.topthird.inset.filled")
        && inspector.contains("rectangle.bottomthird.inset.filled")
        && !inspector.contains(
            "value: \"\\(Int(userConfig.videoSubtitleVerticalPosition))\""
        ),
    "Video inspector should expose an icon-ended relative slider without a number"
)
require(
    inspector,
    contains: "userConfig.resetVideoSubtitleAppearance",
    "Video inspector should expose restore defaults for subtitle appearance"
)
require(
    inspector,
    contains: "ColorPicker(\"Subtitle Color\", selection: subtitleColor",
    "Video inspector should expose the subtitle text color picker"
)
require(
    inspector,
    contains: "ColorPicker(\"Lookup Highlight Color\", selection: subtitleLookupHighlightColor",
    "Video inspector should expose the lookup highlight color picker"
)
require(
    inspector,
    contains: "ColorPicker(\"Lookup Highlight Text Color\", selection: subtitleLookupHighlightTextColor",
    "Video inspector should expose the lookup highlight text color picker"
)
require(
    inspector,
    contains: "var subtitleLookupHighlightTextColor: Binding<Color>",
    "Video inspector should bind the lookup highlight text color setting"
)
require(
    inspector,
    contains: "\"Subtitle Mask\"",
    "Video inspector should expose subtitle mask controls in the Subtitles tab"
)
require(
    inspector,
    contains: "subtitleMaskSection",
    "Video inspector should keep subtitle mask controls in a dedicated section"
)
require(
    inspector,
    contains: "videoEnhancementSection",
    "Video inspector should expose video enhancement controls in the Video tab"
)
require(
    inspector,
    contains: "Toggle(\"Hardware Decoding\", isOn: videoHardwareDecodingEnabled)",
    "Video inspector should expose a hardware decoding toggle"
)
require(
    inspector,
    contains: "Toggle(\"Deinterlace\", isOn: videoDeinterlacingEnabled)",
    "Video inspector should expose a deinterlacing toggle"
)
require(
    inspector,
    contains: "Toggle(\"HDR\", isOn: videoHDREnhancementEnabled)",
    "Video inspector should expose the compact HDR toggle"
)
require(
    inspector,
    contains: "videoEqualizerSlider",
    "Video inspector should expose compact equalizer sliders"
)
require(
    nativeSettings,
    contains: "Section(\"Video\") {\n                nativeSettingsRow(.video)\n            }",
    "the full build should always expose the Video settings group"
)
require(
    player,
    contains: "model.skip(by: -userConfig.videoSeekInterval)",
    "backward seek should use the configured interval"
)
require(
    player,
    contains: "model.skip(by: userConfig.videoSeekInterval)",
    "forward seek should use the configured interval"
)
require(
    player,
    contains: "maskEnabled: userConfig.videoSubtitleMaskEnabled",
    "subtitle overlay should receive the configured mask toggle"
)
require(
    player,
    contains: "maskMode: userConfig.videoSubtitleMaskMode",
    "subtitle overlay should receive the configured mask mode"
)
require(
    player,
    contains: "maskBlurRadius: userConfig.videoSubtitleMaskBlurRadius",
    "subtitle overlay should receive the configured blur radius"
)
require(
    player,
    contains: "maskHiddenOpacity: userConfig.videoSubtitleMaskHiddenOpacity",
    "subtitle overlay should receive the configured transparent-mode opacity"
)
require(
    player,
    contains: "fontFamily: userConfig.videoSubtitleFontFamily",
    "subtitle overlay should receive the configured font family"
)
require(
    player,
    contains: "fontSize: userConfig.videoSubtitleFontSize",
    "subtitle overlay should receive the configured font size"
)
require(
    player,
    contains: "fontWeight: userConfig.videoSubtitleFontWeight",
    "subtitle overlay should receive the configured font weight"
)
require(
    player,
    contains: "edgeStyle: userConfig.videoSubtitleEdgeStyle",
    "subtitle overlay should receive the configured edge style"
)
require(
    player,
    contains: "edgeStrength: userConfig.videoSubtitleEdgeStrength",
    "subtitle overlay should receive the configured edge strength"
)
requireCondition(
    !player.contains("shadowRadius: userConfig.videoSubtitleShadowRadius"),
    "the video screen should stop passing the legacy shadow radius"
)
require(
    player,
    contains: "backgroundOpacity: userConfig.videoSubtitleBackgroundOpacity",
    "subtitle overlay should receive the configured background opacity"
)
require(
    player,
    contains: "backgroundDisabled: userConfig.videoSubtitleBackgroundDisabled",
    "subtitle overlay should receive the configured no-background setting"
)
require(
    player,
    contains: "verticalPosition: userConfig.videoSubtitleVerticalPosition",
    "subtitle overlay should receive the configured vertical position"
)
require(
    player,
    contains: "subtitleColor: userConfig.videoSubtitleColor",
    "subtitle overlay should receive the configured text color"
)
require(
    player,
    contains: "lookupHighlightColor: userConfig.videoSubtitleLookupHighlightColor",
    "subtitle overlay should receive the configured lookup highlight color"
)
require(
    player,
    contains: "lookupHighlightTextColor: userConfig.videoSubtitleLookupHighlightTextColor",
    "subtitle overlay should receive the configured lookup highlight text color"
)
require(
    player,
    contains: "model.setHardwareDecodingEnabled(userConfig.videoHardwareDecodingEnabled)",
    "video screen should synchronize hardware decoding preference into playback engine"
)
require(
    player,
    contains: "model.setDeinterlacingEnabled(userConfig.videoDeinterlacingEnabled)",
    "video screen should synchronize deinterlacing preference into playback engine"
)
require(
    player,
    contains: "model.setHDREnhancementEnabled(userConfig.videoHDREnhancementEnabled)",
    "video screen should synchronize HDR preference into playback engine"
)
require(
    player,
    contains: "synchronizeVideoEqualizerPreferences()",
    "video screen should synchronize equalizer preferences into playback engine"
)
require(
    subtitleOverlay,
    contains: "let lookupHighlightTextColor: Color",
    "subtitle overlay should accept the configured lookup highlight text color"
)
for subtitleOverlayParameter in [
    "let fontWeight: Int",
    "let edgeStyle: VideoSubtitleEdgeStyle",
    "let edgeStrength: Double",
    "let backgroundOpacity: Double",
    "let backgroundDisabled: Bool",
    "let verticalPosition: Double",
] {
    require(
        subtitleOverlay,
        contains: subtitleOverlayParameter,
        "subtitle overlay should accept appearance parameter \(subtitleOverlayParameter)"
    )
}
require(
    subtitleOverlay,
    contains: "SubtitleVerticalPositionLayout(position: verticalPosition)",
    "subtitle overlay should position the measured stack by normalized fraction"
)
requireCondition(
    !subtitleOverlay.contains("* 3"),
    "subtitle overlay should not multiply the configured point offset"
)
require(
    subtitleOverlay,
    contains: "lookupHighlightTextColor: lookupHighlightTextColor",
    "subtitle overlay should pass lookup highlight text color into interactive subtitle rows"
)
require(
    interactiveSubtitleText,
    contains: "let lookupHighlightTextColor: Color",
    "interactive subtitle text view should accept lookup highlight text color"
)
require(
    interactiveSubtitleText,
    contains: "let fontWeight: Int",
    "interactive subtitle text view should accept configured font weight"
)
require(
    interactiveSubtitleText,
    contains: "func subtitleFontWeight() -> NSFont.Weight",
    "interactive subtitle text view should map CSS-style font weights to AppKit font weights"
)
require(
    interactiveSubtitleText,
    contains: ".foregroundColor",
    "interactive subtitle text view should apply lookup highlight text color to the selected range"
)
require(
    localization,
    contains: "\"Lookup Highlight Text Color\"",
    "lookup highlight text color label should be localized"
)
for localizedVideoEnhancementLabel in [
    "\"Video Enhancement\"",
    "\"Hardware Decoding\"",
    "\"Deinterlace\"",
    "\"HDR\"",
    "\"Brightness\"",
    "\"Contrast\"",
    "\"Saturation\"",
    "\"Gamma\"",
    "\"Hue\"",
] {
    require(
        localization,
        contains: localizedVideoEnhancementLabel,
        "video enhancement label should be localized: \(localizedVideoEnhancementLabel)"
    )
}
for localizedSubtitleAppearanceLabel in [
    "\"Subtitle Weight\"",
    "\"Edge Style\"",
    "\"Edge Strength\"",
    "\"Soft Shadow\"",
    "\"Clear Outline\"",
    "\"High Contrast\"",
    "\"Background Opacity\"",
    "\"No Background\"",
    "\"Let subtitle background stay transparent.\"",
    "\"Vertical Position\"",
    "\"Restore Defaults\"",
] {
    require(
        localization,
        contains: localizedSubtitleAppearanceLabel,
        "subtitle appearance label should be localized: \(localizedSubtitleAppearanceLabel)"
    )
}
for localizedSubtitleAlignmentLabel in [
    "\"Align Subtitle to Current Time\"",
    "\"Align Previous Subtitle to Current Time\"",
    "\"Align Next Subtitle to Current Time\"",
    "\"Previous\"",
    "\"Next\"",
] {
    require(
        localization,
        contains: localizedSubtitleAlignmentLabel,
        "subtitle alignment label should be localized: \(localizedSubtitleAlignmentLabel)"
    )
}
for actionID in [
    "video.mineCurrentSubtitle",
    "video.toggleSubtitleGapFastForward",
    "video.previousSubtitleCue",
    "video.nextSubtitleCue",
    "video.alignPreviousSubtitleToCurrentTime",
    "video.alignNextSubtitleToCurrentTime",
    "video.toggleSubtitlesVisible",
    "video.cycleSubtitleTrack",
    "video.volumeDown",
    "video.volumeUp",
] {
    require(
        shortcutActions,
        contains: actionID,
        "Video shortcut actions should include \(actionID)"
    )
    require(
        player,
        contains: actionID
            .replacingOccurrences(of: "video.", with: "VideoShortcutActions.")
            .replacingOccurrences(of: "previousSubtitleCue", with: "previousSubtitleCue.id")
            .replacingOccurrences(of: "nextSubtitleCue", with: "nextSubtitleCue.id")
            .replacingOccurrences(of: "toggleSubtitlesVisible", with: "toggleSubtitlesVisible.id")
            .replacingOccurrences(of: "cycleSubtitleTrack", with: "cycleSubtitleTrack.id")
            .replacingOccurrences(of: "volumeDown", with: "volumeDown.id")
            .replacingOccurrences(of: "volumeUp", with: "volumeUp.id"),
        "Video shortcut handlers should wire \(actionID)"
    )
}
require(
    shortcutActions,
    contains: "key: \"z\"",
    "mine-current-subtitle should use the asbplayer macOS Z binding"
)
require(
    shortcutActions,
    contains: "EventModifiers.control.rawValue",
    "mine-current-subtitle should include Control"
)
require(
    shortcutActions,
    contains: "EventModifiers.shift.rawValue",
    "mine-current-subtitle should include Shift"
)
requireCondition(
    player.contains(".onTapGesture(count: 2)")
        || player.contains("TapGesture(count: 2)"),
    "video canvas should support double-click full screen"
)
require(
    player,
    contains: "toggleFullScreenFromPointer()",
    "video canvas double-click should route through the pointer full-screen toggle"
)
require(
    player,
    contains: "togglePlaybackFromPointer()",
    "video canvas single-click should route through the pointer playback toggle"
)
require(
    player,
    contains: ".onContinuousHover { phase in",
    "video canvas should reveal playback chrome when the pointer moves over the video"
)
require(
    player,
    contains: "hidePlaybackChromeForPointerExit()",
    "video playback chrome should hide when the pointer leaves the app/window or the app becomes inactive"
)
for key in [
    "\"Remember Playback State\"",
    "\"Auto-pause on Lookup\"",
    "\"Fast-forward Subtitle Gaps\"",
    "\"Fast-forward Speed\"",
    "\"Temporarily speeds through gaps between subtitle lines.\"",
    "\"Restores playback position, subtitles, speed, timing, and audio track for each video.\"",
    "\"Control Bar Layout\"",
    "\"Floating\"",
    "\"Compact Bottom\"",
    "\"Subtitle Mask\"",
    "\"Subtitle Appearance\"",
    "\"Subtitle Font\"",
    "\"System Default\"",
    "\"Subtitle Size\"",
    "\"Subtitle Color\"",
    "\"Lookup Highlight Color\"",
    "\"Customize subtitle typography, text color, and lookup highlight background.\"",
    "\"Defaults match asbplayer text subtitles: system font and 36 px size.\"",
    "\"Mask subtitles until hover\"",
    "\"Mask Mode\"",
    "\"Blur Radius\"",
    "\"Hidden Opacity\"",
    "\"Transparent\"",
    "\"Previous Subtitle\"",
    "\"Next Subtitle\"",
    "\"Show / Hide Subtitles\"",
    "\"Cycle Subtitle Track\"",
    "\"Volume Down\"",
    "\"Volume Up\"",
] {
    require(
        localization,
        contains: key,
        "Localizable.xcstrings should include \(key) for subtitle mask UI"
    )
}

print("Video settings contract tests passed")
