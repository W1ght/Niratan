import Foundation

nonisolated enum VideoShaderPreset: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case off
    case anime4KFast
    case anime4KHighQuality

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .off:
            String(localized: "Off")
        case .anime4KFast:
            String(localized: "Anime4K Fast")
        case .anime4KHighQuality:
            String(localized: "Anime4K High Quality")
        }
    }

    var shaderFileNames: [String] {
        switch self {
        case .off:
            []
        case .anime4KFast:
            [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_M.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_S.glsl",
            ]
        case .anime4KHighQuality:
            [
                "Anime4K_Clamp_Highlights.glsl",
                "Anime4K_Restore_CNN_VL.glsl",
                "Anime4K_Upscale_CNN_x2_VL.glsl",
                "Anime4K_AutoDownscalePre_x2.glsl",
                "Anime4K_AutoDownscalePre_x4.glsl",
                "Anime4K_Upscale_CNN_x2_M.glsl",
            ]
        }
    }
}
