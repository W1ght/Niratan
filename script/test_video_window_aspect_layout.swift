// test-sources: Features/Video/Playback/PlaybackEngine.swift Features/Video/VideoWindowChromeController.swift Features/Video/Remote/RemoteVideoSource.swift Features/Video/Playback/VideoTrack.swift Features/Video/Playback/VideoShaderPreset.swift Models/Subtitle.swift Features/Video/Remote/YouTubeURLParser.swift
import AppKit
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func approximatelyEqual(
    _ lhs: CGFloat,
    _ rhs: CGFloat,
    tolerance: CGFloat = 0.001
) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func approximatelyEqual(
    _ lhs: CGSize,
    _ rhs: CGSize,
    tolerance: CGFloat = 0.001
) -> Bool {
    approximatelyEqual(lhs.width, rhs.width, tolerance: tolerance)
        && approximatelyEqual(lhs.height, rhs.height, tolerance: tolerance)
}

@main
private enum VideoWindowAspectLayoutTests {
    static func main() {
        expect(
            VideoAspectRatio.ratio16x9.numericValue == 16.0 / 9.0,
            "explicit 16:9 override should expose its numeric aspect ratio"
        )
        expect(
            VideoAspectRatio.automatic.numericValue == nil,
            "automatic aspect ratio should defer to the media display size"
        )

        let automaticWide = VideoWindowAspectLayout.videoAspectRatio(
            displaySize: CGSize(width: 1920, height: 1080),
            override: .automatic,
            rotation: 0
        )
        expect(
            approximatelyEqual(automaticWide ?? 0, 16.0 / 9.0),
            "automatic window aspect should use mpv display dimensions"
        )

        let rotatedWide = VideoWindowAspectLayout.videoAspectRatio(
            displaySize: CGSize(width: 1920, height: 1080),
            override: .automatic,
            rotation: 90
        )
        expect(
            approximatelyEqual(rotatedWide ?? 0, 9.0 / 16.0),
            "90-degree rotation should swap media dimensions for window sizing"
        )

        let explicitOverride = VideoWindowAspectLayout.videoAspectRatio(
            displaySize: CGSize(width: 1920, height: 1080),
            override: .ratio4x3,
            rotation: 90
        )
        expect(
            approximatelyEqual(explicitOverride ?? 0, 3.0 / 4.0),
            "rotation should apply to explicit aspect-ratio overrides"
        )

        let fullScreenViewport = VideoWindowAspectLayout.videoViewport(
            in: CGSize(width: 1470, height: 923),
            renderGeometry: VideoRenderGeometry(
                osdSize: CGSize(width: 2940, height: 1846),
                topMargin: 96,
                bottomMargin: 96,
                leftMargin: 0,
                rightMargin: 0
            ),
            aspectRatio: 16.0 / 9.0
        )
        expect(
            approximatelyEqual(fullScreenViewport.minX, 0)
                && approximatelyEqual(fullScreenViewport.minY, 48)
                && approximatelyEqual(fullScreenViewport.width, 1470)
                && approximatelyEqual(fullScreenViewport.height, 827),
            "full-screen viewport should follow mpv's actual rounded letterbox margins"
        )

        let asymmetricViewport = VideoWindowAspectLayout.videoViewport(
            in: CGSize(width: 1200, height: 800),
            renderGeometry: VideoRenderGeometry(
                osdSize: CGSize(width: 2400, height: 1600),
                topMargin: 80,
                bottomMargin: 160,
                leftMargin: 120,
                rightMargin: 240
            ),
            aspectRatio: 16.0 / 9.0
        )
        expect(
            approximatelyEqual(asymmetricViewport.minX, 60)
                && approximatelyEqual(asymmetricViewport.minY, 40)
                && approximatelyEqual(asymmetricViewport.width, 1020)
                && approximatelyEqual(asymmetricViewport.height, 680),
            "mpv OSD margins should be scaled into the SwiftUI video surface"
        )

        let invalidRenderGeometryViewport = VideoWindowAspectLayout.videoViewport(
            in: CGSize(width: 1470, height: 923),
            renderGeometry: VideoRenderGeometry(
                osdSize: CGSize(width: 0, height: 0),
                topMargin: 0,
                bottomMargin: 0,
                leftMargin: 0,
                rightMargin: 0
            ),
            aspectRatio: 16.0 / 9.0
        )
        expect(
            approximatelyEqual(invalidRenderGeometryViewport.minY, 48.0625)
                && approximatelyEqual(invalidRenderGeometryViewport.height, 826.875),
            "unavailable mpv OSD dimensions should fall back to aspect-fit geometry"
        )

        let exactViewport = VideoWindowAspectLayout.videoViewport(
            in: CGSize(width: 1470, height: 826.875),
            renderGeometry: nil,
            aspectRatio: 16.0 / 9.0
        )
        expect(
            approximatelyEqual(exactViewport.minX, 0)
                && approximatelyEqual(exactViewport.minY, 0)
                && approximatelyEqual(exactViewport.width, 1470)
                && approximatelyEqual(exactViewport.height, 826.875),
            "an exact-aspect window should use the complete video surface"
        )

        let pillarboxedViewport = VideoWindowAspectLayout.videoViewport(
            in: CGSize(width: 1600, height: 900),
            renderGeometry: nil,
            aspectRatio: 4.0 / 3.0
        )
        expect(
            approximatelyEqual(pillarboxedViewport.minX, 200)
                && approximatelyEqual(pillarboxedViewport.minY, 0)
                && approximatelyEqual(pillarboxedViewport.width, 1200)
                && approximatelyEqual(pillarboxedViewport.height, 900),
            "a narrower picture should stay centered between equal pillarboxes"
        )

        let fallbackViewport = VideoWindowAspectLayout.videoViewport(
            in: CGSize(width: 1200, height: 700),
            renderGeometry: nil,
            aspectRatio: nil
        )
        expect(
            fallbackViewport == CGRect(x: 0, y: 0, width: 1200, height: 700),
            "missing media geometry should fall back to the complete video surface"
        )

        let invalidViewport = VideoWindowAspectLayout.videoViewport(
            in: CGSize(width: 1200, height: 700),
            renderGeometry: nil,
            aspectRatio: .nan
        )
        expect(
            invalidViewport == CGRect(x: 0, y: 0, width: 1200, height: 700),
            "invalid media geometry should fall back to the complete video surface"
        )

        let contentSize = VideoWindowAspectLayout.fittedContentSize(
            currentContentSize: CGSize(width: 1200, height: 760),
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 340,
            visibleContentFrame: CGRect(x: 0, y: 0, width: 2000, height: 1200)
        )
        expect(
            approximatelyEqual(contentSize.width, contentSize.height * 16.0 / 9.0 + 340),
            "windowed content width should reserve sidebar width after aspect-fitting the video"
        )

        let clampedContentSize = VideoWindowAspectLayout.fittedContentSize(
            currentContentSize: CGSize(width: 1600, height: 900),
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 340,
            visibleContentFrame: CGRect(x: 0, y: 0, width: 1280, height: 720)
        )
        expect(
            clampedContentSize.width <= 1280,
            "aspect-fitting should shrink oversized video windows to the visible display width"
        )
        expect(
            approximatelyEqual(
                clampedContentSize.width,
                clampedContentSize.height * 16.0 / 9.0 + 340
            ),
            "visible-display clamping should preserve the video-plus-sidebar aspect relationship"
        )

        let resolvedSidebar = VideoWindowAspectLayout.aspectFittingSidebarWidth(
            contentSize: CGSize(width: 1700, height: 765),
            videoAspectRatio: 16.0 / 9.0,
            proposedWidth: 340,
            minWidth: 320,
            maxWidth: 560
        )
        expect(
            approximatelyEqual(resolvedSidebar, 340),
            "study sidebar width should match the current window width when that preserves the video aspect"
        )

        let currentFrameSize = CGSize(width: 1280, height: 748)
        let titlebarDecoration = CGSize(width: 0, height: 28)
        let minimumFrameSize = CGSize(width: 900, height: 620)

        let horizontalResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: currentFrameSize,
            proposedFrameSize: CGSize(width: 1600, height: 748),
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 0,
            minimumFrameSize: minimumFrameSize
        )
        expect(
            approximatelyEqual(horizontalResize.width, 1600),
            "horizontal resizing should preserve the proposed width"
        )
        expect(
            approximatelyEqual(horizontalResize.height, 928),
            "horizontal resizing should derive content height before restoring title-bar height"
        )

        let verticalResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: currentFrameSize,
            proposedFrameSize: CGSize(width: 1280, height: 928),
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 0,
            minimumFrameSize: minimumFrameSize
        )
        expect(
            approximatelyEqual(verticalResize.width, 1600),
            "vertical resizing should derive width from the proposed content height"
        )
        expect(
            approximatelyEqual(verticalResize.height, 928),
            "vertical resizing should preserve the proposed frame height"
        )

        let cornerResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: currentFrameSize,
            proposedFrameSize: CGSize(width: 1480, height: 808),
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 0,
            minimumFrameSize: minimumFrameSize
        )
        expect(
            approximatelyEqual(cornerResize.width, 1480),
            "corner resizing should honor the dominant normalized width delta"
        )
        expect(
            approximatelyEqual(cornerResize.height, 860.5),
            "corner resizing should derive the paired dimension from the dominant delta"
        )

        let repeatedCornerProposal = CGSize(width: 1480, height: 808)
        let unfrozenFirstResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: currentFrameSize,
            proposedFrameSize: repeatedCornerProposal,
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 0,
            minimumFrameSize: minimumFrameSize,
            resizeDriver: nil
        )
        let unfrozenSecondResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: unfrozenFirstResize,
            proposedFrameSize: repeatedCornerProposal,
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 0,
            minimumFrameSize: minimumFrameSize,
            resizeDriver: nil
        )
        let unfrozenThirdResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: unfrozenSecondResize,
            proposedFrameSize: repeatedCornerProposal,
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 0,
            minimumFrameSize: minimumFrameSize,
            resizeDriver: nil
        )
        expect(
            approximatelyEqual(unfrozenFirstResize, CGSize(width: 1480, height: 860.5))
                && approximatelyEqual(
                    unfrozenSecondResize,
                    CGSize(width: 1386.6666666667, height: 808)
                )
                && approximatelyEqual(unfrozenThirdResize, unfrozenFirstResize)
                && !approximatelyEqual(unfrozenFirstResize, unfrozenSecondResize),
            "re-evaluating the resize driver against the previously corrected frame should reproduce the old alternating-size jitter"
        )

        var widthDrivenCurrentSize = currentFrameSize
        var widthDrivenResults: [CGSize] = []
        for proposedWidth in [1320.0, 1400.0, 1480.0] {
            let result = VideoWindowAspectLayout.constrainedFrameSize(
                currentFrameSize: widthDrivenCurrentSize,
                proposedFrameSize: CGSize(width: proposedWidth, height: 748),
                frameDecorationSize: titlebarDecoration,
                videoAspectRatio: 16.0 / 9.0,
                sidebarWidth: 0,
                minimumFrameSize: minimumFrameSize,
                resizeDriver: .width
            )
            widthDrivenResults.append(result)
            widthDrivenCurrentSize = result
        }
        expect(
            widthDrivenResults.indices.dropFirst().allSatisfy { index in
                widthDrivenResults[index].width > widthDrivenResults[index - 1].width
                    && widthDrivenResults[index].height > widthDrivenResults[index - 1].height
            },
            "a frozen width driver should produce a monotonic frame sequence"
        )
        let repeatedWidthDrivenResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: widthDrivenCurrentSize,
            proposedFrameSize: CGSize(width: 1480, height: 748),
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 0,
            minimumFrameSize: minimumFrameSize,
            resizeDriver: .width
        )
        expect(
            approximatelyEqual(repeatedWidthDrivenResize, widthDrivenCurrentSize),
            "a frozen width driver should return the same frame for a repeated proposal"
        )

        var heightDrivenCurrentSize = currentFrameSize
        var heightDrivenResults: [CGSize] = []
        for proposedHeight in [768.0, 828.0, 928.0] {
            let result = VideoWindowAspectLayout.constrainedFrameSize(
                currentFrameSize: heightDrivenCurrentSize,
                proposedFrameSize: CGSize(width: 1280, height: proposedHeight),
                frameDecorationSize: titlebarDecoration,
                videoAspectRatio: 16.0 / 9.0,
                sidebarWidth: 0,
                minimumFrameSize: minimumFrameSize,
                resizeDriver: .height
            )
            heightDrivenResults.append(result)
            heightDrivenCurrentSize = result
        }
        expect(
            heightDrivenResults.indices.dropFirst().allSatisfy { index in
                heightDrivenResults[index].width > heightDrivenResults[index - 1].width
                    && heightDrivenResults[index].height > heightDrivenResults[index - 1].height
            },
            "a frozen height driver should produce a monotonic frame sequence"
        )
        let repeatedHeightDrivenResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: heightDrivenCurrentSize,
            proposedFrameSize: CGSize(width: 1280, height: 928),
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 0,
            minimumFrameSize: minimumFrameSize,
            resizeDriver: .height
        )
        expect(
            approximatelyEqual(repeatedHeightDrivenResize, heightDrivenCurrentSize),
            "a frozen height driver should return the same frame for a repeated proposal"
        )

        let sidebarResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: CGSize(width: 1620, height: 748),
            proposedFrameSize: CGSize(width: 1940, height: 748),
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 340,
            minimumFrameSize: minimumFrameSize
        )
        expect(
            approximatelyEqual(sidebarResize.width, 1940),
            "study-sidebar resizing should preserve the proposed total width"
        )
        expect(
            approximatelyEqual(sidebarResize.height, 928),
            "study-sidebar resizing should keep only the video surface aspect-correct"
        )

        let sidebarWidth: CGFloat = 340
        var sidebarWidthDrivenCurrentSize = CGSize(width: 1620, height: 748)
        var sidebarWidthDrivenResults: [CGSize] = []
        for proposedWidth in [1760.0, 1850.0, 1940.0] {
            let result = VideoWindowAspectLayout.constrainedFrameSize(
                currentFrameSize: sidebarWidthDrivenCurrentSize,
                proposedFrameSize: CGSize(width: proposedWidth, height: 748),
                frameDecorationSize: titlebarDecoration,
                videoAspectRatio: 16.0 / 9.0,
                sidebarWidth: sidebarWidth,
                minimumFrameSize: minimumFrameSize,
                resizeDriver: .width
            )
            sidebarWidthDrivenResults.append(result)
            sidebarWidthDrivenCurrentSize = result
        }
        expect(
            sidebarWidthDrivenResults.indices.dropFirst().allSatisfy { index in
                sidebarWidthDrivenResults[index].width
                    > sidebarWidthDrivenResults[index - 1].width
                    && sidebarWidthDrivenResults[index].height
                        > sidebarWidthDrivenResults[index - 1].height
            },
            "a frozen width driver should keep sidebar-inclusive resizing monotonic"
        )
        expect(
            sidebarWidthDrivenResults.allSatisfy { result in
                approximatelyEqual(
                    result.width - sidebarWidth,
                    (result.height - titlebarDecoration.height) * 16.0 / 9.0
                )
            },
            "a frozen width driver should reserve the sidebar while preserving the video aspect"
        )
        let repeatedSidebarWidthResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: sidebarWidthDrivenCurrentSize,
            proposedFrameSize: CGSize(width: 1940, height: 748),
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: sidebarWidth,
            minimumFrameSize: minimumFrameSize,
            resizeDriver: .width
        )
        expect(
            approximatelyEqual(repeatedSidebarWidthResize, sidebarWidthDrivenCurrentSize),
            "a frozen width driver should keep a repeated sidebar proposal idempotent"
        )

        var sidebarHeightDrivenCurrentSize = CGSize(width: 1620, height: 748)
        var sidebarHeightDrivenResults: [CGSize] = []
        for proposedHeight in [768.0, 828.0, 888.0] {
            let result = VideoWindowAspectLayout.constrainedFrameSize(
                currentFrameSize: sidebarHeightDrivenCurrentSize,
                proposedFrameSize: CGSize(width: 1620, height: proposedHeight),
                frameDecorationSize: titlebarDecoration,
                videoAspectRatio: 16.0 / 9.0,
                sidebarWidth: sidebarWidth,
                minimumFrameSize: minimumFrameSize,
                resizeDriver: .height
            )
            sidebarHeightDrivenResults.append(result)
            sidebarHeightDrivenCurrentSize = result
        }
        expect(
            sidebarHeightDrivenResults.indices.dropFirst().allSatisfy { index in
                sidebarHeightDrivenResults[index].width
                    > sidebarHeightDrivenResults[index - 1].width
                    && sidebarHeightDrivenResults[index].height
                        > sidebarHeightDrivenResults[index - 1].height
            },
            "a frozen height driver should keep sidebar-inclusive resizing monotonic"
        )
        expect(
            sidebarHeightDrivenResults.allSatisfy { result in
                approximatelyEqual(
                    result.width - sidebarWidth,
                    (result.height - titlebarDecoration.height) * 16.0 / 9.0
                )
            },
            "a frozen height driver should reserve the sidebar while preserving the video aspect"
        )
        let repeatedSidebarHeightResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: sidebarHeightDrivenCurrentSize,
            proposedFrameSize: CGSize(width: 1620, height: 888),
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: sidebarWidth,
            minimumFrameSize: minimumFrameSize,
            resizeDriver: .height
        )
        expect(
            approximatelyEqual(repeatedSidebarHeightResize, sidebarHeightDrivenCurrentSize),
            "a frozen height driver should keep a repeated sidebar proposal idempotent"
        )

        let minimumResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: currentFrameSize,
            proposedFrameSize: CGSize(width: 800, height: 500),
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 0,
            minimumFrameSize: minimumFrameSize
        )
        expect(
            approximatelyEqual(minimumResize.width, 592 * 16.0 / 9.0),
            "minimum height should grow width along the video ratio"
        )
        expect(
            approximatelyEqual(minimumResize.height, 620),
            "live resizing should respect the minimum frame height"
        )

        let iinaMinimumFrameSize = CGSize(width: 285, height: 120)
        let iinaMinimumResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: CGSize(width: 1280, height: 720),
            proposedFrameSize: CGSize(width: 240, height: 120),
            frameDecorationSize: .zero,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 0,
            minimumFrameSize: iinaMinimumFrameSize,
            resizeDriver: .width
        )
        expect(
            approximatelyEqual(
                iinaMinimumResize,
                CGSize(width: 285, height: 160.3125)
            ),
            "IINA's 285x120 minimum envelope should resolve to an aspect-locked 285x160.3125 frame for 16:9 video"
        )

        let oversizedResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: CGSize(width: 1280, height: 720),
            proposedFrameSize: CGSize(width: 8192, height: 4608),
            frameDecorationSize: .zero,
            videoAspectRatio: 16.0 / 9.0,
            sidebarWidth: 0,
            minimumFrameSize: iinaMinimumFrameSize,
            resizeDriver: .width
        )
        expect(
            approximatelyEqual(
                oversizedResize,
                CGSize(width: 8192, height: 4608)
            ),
            "aspect-locked live resizing should not clamp a valid large proposal to the visible screen or an artificial maximum"
        )

        let invalidResizeProposal = CGSize(width: 1400, height: 900)
        let invalidResize = VideoWindowAspectLayout.constrainedFrameSize(
            currentFrameSize: currentFrameSize,
            proposedFrameSize: invalidResizeProposal,
            frameDecorationSize: titlebarDecoration,
            videoAspectRatio: .nan,
            sidebarWidth: 0,
            minimumFrameSize: minimumFrameSize
        )
        expect(
            invalidResize == invalidResizeProposal,
            "invalid layout inputs should leave AppKit's proposal unchanged"
        )

        print("Video window aspect layout tests passed")
    }
}
