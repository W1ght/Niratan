import SwiftUI

struct VideoAmbientPresentation: Equatable {
    let usesBlurredLetterbox: Bool
    let workspaceCornerRadius: CGFloat

    static func resolve(isFullScreen: Bool) -> VideoAmbientPresentation {
        VideoAmbientPresentation(
            usesBlurredLetterbox: false,
            workspaceCornerRadius: 0
        )
    }
}

struct VideoAmbientBackdrop: View {
    let image: NSImage?
    let presentation: VideoAmbientPresentation

    var body: some View {
        GeometryReader { geometry in
            if presentation.usesBlurredLetterbox, let image {
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .saturation(0.72)
                        .blur(radius: 32)

                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .opacity(0.32)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .modifier(VideoAmbientGlassSurface(cornerRadius: presentation.workspaceCornerRadius))
                .mask {
                    VideoLetterboxMask(videoAspectSize: image.size)
                        .fill(.white, style: FillStyle(eoFill: true))
                }
                .allowsHitTesting(false)
            }
        }
    }
}

nonisolated private struct VideoLetterboxMask: Shape {
    let videoAspectSize: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        guard videoAspectSize.width > 0, videoAspectSize.height > 0 else {
            return path
        }

        let videoAspect = videoAspectSize.width / videoAspectSize.height
        let containerAspect = rect.width / max(rect.height, 1)
        let videoRect: CGRect
        if containerAspect > videoAspect {
            let width = rect.height * videoAspect
            videoRect = CGRect(
                x: rect.midX - width / 2,
                y: rect.minY,
                width: width,
                height: rect.height
            )
        } else {
            let height = rect.width / videoAspect
            videoRect = CGRect(
                x: rect.minX,
                y: rect.midY - height / 2,
                width: rect.width,
                height: height
            )
        }
        path.addRect(videoRect)
        return path
    }
}

private struct VideoAmbientGlassSurface: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}
