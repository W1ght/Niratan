import AppKit
import SwiftUI

/// Page background for surfaces that host glass cards. A solid neutral layer keeps the
/// recessed tone that separates cards from the page without a blur layer under glass.
struct NativeGlassPageBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NativeShelfPageBackground()
            .overlay {
                NativeGlassPalette.recessTint(for: colorScheme)
                    .ignoresSafeArea(.container, edges: .top)
                    .allowsHitTesting(false)
            }
    }
}

struct NativeShelfPageBackground: View {
    @Environment(UserConfig.self) private var userConfig
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            NativeGlassPalette.tint(for: userConfig, colorScheme: colorScheme)

            LinearGradient(
                colors: [
                    NativeGlassPalette.depthTint(for: colorScheme),
                    .clear,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea(.container, edges: .top)
    }
}

struct NativeGlassTopScrim: View {
    @Environment(UserConfig.self) private var userConfig
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: [
                NativeGlassPalette.scrimTint(for: userConfig, colorScheme: colorScheme),
                .clear
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

enum NativeGlassPalette {
    static func tint(for userConfig: UserConfig, colorScheme: ColorScheme) -> Color {
        if userConfig.theme == .custom {
            return userConfig.customBackgroundColor.opacity(colorScheme == .dark ? 0.18 : 0.12)
        }

        if usesSepiaTint(userConfig: userConfig, colorScheme: colorScheme) {
            return Color(red: 0.949, green: 0.886, blue: 0.788).opacity(colorScheme == .dark ? 0.10 : 0.24)
        }

        return colorScheme == .dark ? Color.black.opacity(0.16) : Color.white.opacity(0.22)
    }

    static func cardTint(for userConfig: UserConfig, colorScheme: ColorScheme) -> Color {
        if userConfig.theme == .custom {
            return userConfig.customBackgroundColor.opacity(colorScheme == .dark ? 0.16 : 0.10)
        }

        if usesSepiaTint(userConfig: userConfig, colorScheme: colorScheme) {
            return Color(red: 0.949, green: 0.886, blue: 0.788).opacity(colorScheme == .dark ? 0.08 : 0.20)
        }

        return colorScheme == .dark ? Color.white.opacity(0.035) : Color.white.opacity(0.26)
    }

    static func scrimTint(for userConfig: UserConfig, colorScheme: ColorScheme) -> Color {
        if userConfig.theme == .custom {
            return userConfig.customBackgroundColor.opacity(colorScheme == .dark ? 0.26 : 0.22)
        }

        if usesSepiaTint(userConfig: userConfig, colorScheme: colorScheme) {
            return Color(red: 0.949, green: 0.886, blue: 0.788).opacity(colorScheme == .dark ? 0.18 : 0.32)
        }

        return colorScheme == .dark ? Color.black.opacity(0.36) : Color.white.opacity(0.42)
    }

    static func recessTint(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.03) : Color.black.opacity(0.055)
    }

    static func depthTint(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.black.opacity(0.16) : Color.white.opacity(0.12)
    }

    static func stroke(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? Color.white.opacity(0.13) : Color.black.opacity(0.09)
    }

    private static func usesSepiaTint(userConfig: UserConfig, colorScheme: ColorScheme) -> Bool {
        userConfig.theme == .sepia
        || (userConfig.theme == .system && userConfig.systemLightSepia && colorScheme == .light)
    }
}

private struct NativeGlassCardSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(UserConfig.self) private var userConfig
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .background {
                shape
                    .fill(NativeGlassPalette.cardTint(for: userConfig, colorScheme: colorScheme))
                    .overlay {
                        shape.strokeBorder(NativeGlassPalette.stroke(for: colorScheme), lineWidth: 0.7)
                    }
            }
            .clipShape(shape)
            .nativeGlassCardEffect(cornerRadius: cornerRadius)
    }
}

private struct NativeGlassCapsuleSurfaceModifier: ViewModifier {
    @Environment(UserConfig.self) private var userConfig
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                Capsule()
                    .fill(NativeGlassPalette.cardTint(for: userConfig, colorScheme: colorScheme))
                    .overlay {
                        Capsule().strokeBorder(NativeGlassPalette.stroke(for: colorScheme), lineWidth: 0.8)
                    }
            }
            .contentShape(Capsule())
            .nativeGlassCapsuleEffect()
    }
}

extension View {
    func nativeGlassCardSurface(cornerRadius: CGFloat = 18) -> some View {
        modifier(NativeGlassCardSurfaceModifier(cornerRadius: cornerRadius))
    }

    func nativeGlassCapsuleSurface() -> some View {
        modifier(NativeGlassCapsuleSurfaceModifier())
    }
}

private extension View {
    @ViewBuilder
    func nativeGlassCardEffect(cornerRadius: CGFloat) -> some View {
        self.glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    @ViewBuilder
    func nativeGlassCapsuleEffect() -> some View {
        self.glassEffect(.regular.interactive(), in: Capsule())
    }
}
