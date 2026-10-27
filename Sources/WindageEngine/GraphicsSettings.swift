//
//  GraphicsSettings.swift
//  WindageEngine
//

import Foundation
import QuartzCore

/// **How much a game draws — a player's trade of looks for speed.**
///
/// The settings every 3D game's graphics menu has, each one something the engine really does: shadows
/// (``ShadowMap``/``ShadowCascades``), how far and how thickly scattered things are drawn, the scene's size against the
/// window (``SceneScaling``), anti-aliasing (``FrameRenderer/sampleCount``) and the frame rate asked of the display.
/// **The defaults are the High preset**, the game as made with 4× anti-aliasing: nothing here makes a game look worse
/// unless a player asks it to. A game whose world has no plants simply does not offer those two rows.
///
/// Saved with `Codable`; a saved set missing a setting added since keeps everything it did say.
public nonisolated struct GraphicsSettings: Equatable, Sendable, Codable {
    public enum Shadows: String, CaseIterable, Sendable, Codable {
        /// None from the sun.
        case off
        /// **Near shadows only**: the nearer cascades, at 1024 texels a side — softer, and nothing drawn into the far
        /// cascade, which is where the time goes. Measured in a dense wood: a smaller map alone saved one millisecond, the
        /// far cascade's casters seven.
        case low
        /// Every cascade at 2048 a side.
        case high

        /// How many of the sun's cascades get casters, nearest first, of `count`; the rest are left empty and read as lit.
        public func castingCascades(of count: Int) -> Int {
            switch self {
            case .off: 0
            case .low: max(count - 1, 1)
            case .high: count
            }
        }

        /// Texels per side of each cascade; nil when off.
        public var resolution: Int? {
            switch self {
            case .off: nil
            case .low: 1024
            case .high: 2048
            }
        }

        /// The cascades for this quality at a game's own splits and depth range; nil when off.
        public func cascades(splits: [Float], lightDepthRange: Float) -> ShadowCascades? {
            resolution.map { ShadowCascades(splits: splits, resolution: $0, lightDepthRange: lightDepthRange) }
        }
    }

    /// How large the 3D scene is drawn against the window. The interface is always sharp.
    public enum RenderScale: String, CaseIterable, Sendable, Codable {
        /// The game's own choice — whatever it passes as `automatic` to ``sceneScaling(automatic:)``.
        case automatic
        /// The window's size at any width — sharpest, and the most a Mac is asked to draw.
        case full
        case threeQuarters
        case half

        public func sceneScaling(automatic: SceneScaling) -> SceneScaling {
            switch self {
            case .automatic: automatic
            case .full: .native
            case .threeQuarters: .fraction(0.75)
            case .half: .fraction(0.5)
            }
        }
    }

    public var shadows: Shadows = .high
    /// How far scattered things are drawn, as a share of each kind's own distance (``drawDistanceRange``).
    public var drawDistance: Float = 1
    /// The share of thin ground cover drawn — grass, flowers, crops (``plantDensityRange``, ``keeps(_:atDensity:)``).
    /// Trees and bushes stay whole: thinning them changes the world, not its cost.
    public var plantDensity: Float = 1
    public var renderScale: RenderScale = .automatic
    /// Frames a second asked of the display (``frameRates``) — ``frameRateRange``.
    public var frameRate: Int = 60
    /// Samples per pixel in the scene (``FrameRenderer/sampleCount``): 1 is none, 4 smooths every edge.
    public var antiAliasing: Int = 4

    public static let drawDistanceRange: ClosedRange<Float> = 0.5...1
    public static let plantDensityRange: ClosedRange<Float> = 0.25...1
    public static let frameRates = [60, 30]
    public static let antiAliasingChoices = [1, 2, 4]

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GraphicsSettings()
        shadows = (try? c.decodeIfPresent(Shadows.self, forKey: .shadows)) ?? d.shadows
        drawDistance = (try? c.decodeIfPresent(Float.self, forKey: .drawDistance)) ?? d.drawDistance
        plantDensity = (try? c.decodeIfPresent(Float.self, forKey: .plantDensity)) ?? d.plantDensity
        renderScale = (try? c.decodeIfPresent(RenderScale.self, forKey: .renderScale)) ?? d.renderScale
        frameRate = (try? c.decodeIfPresent(Int.self, forKey: .frameRate)) ?? d.frameRate
        antiAliasing = (try? c.decodeIfPresent(Int.self, forKey: .antiAliasing)) ?? d.antiAliasing
    }

    /// **Clamped where it is used**, so a stale saved value cannot ask for something the screen never offers.
    public var clamped: GraphicsSettings {
        var s = self
        s.drawDistance = drawDistance.isFinite
            ? min(max(drawDistance, Self.drawDistanceRange.lowerBound), Self.drawDistanceRange.upperBound) : 1
        s.plantDensity = plantDensity.isFinite
            ? min(max(plantDensity, Self.plantDensityRange.lowerBound), Self.plantDensityRange.upperBound) : 1
        if !Self.frameRates.contains(frameRate) { s.frameRate = 60 }
        if !Self.antiAliasingChoices.contains(antiAliasing) { s.antiAliasing = 1 }
        return s
    }

    /// What to ask the display link for (``FrameRenderer/makeDisplayLink(for:frameRateRange:)``).
    public var frameRateRange: CAFrameRateRange {
        let rate = Float(clamped.frameRate)
        return CAFrameRateRange(minimum: min(30, rate), maximum: rate, preferred: rate)
    }

    // MARK: Presets

    public enum Preset: String, CaseIterable, Sendable {
        case low, medium, high

        /// The engine's presets: High is the defaults; Medium near shadows, 2×, a little less far and thick; Low no
        /// shadows, no anti-aliasing, half the ground cover and the scene at 75%. Measured in a dense wood at
        /// 1960×1490 (Debug): 25.7, 18.6 and 9.2 ms.
        public var settings: GraphicsSettings {
            var s = GraphicsSettings()
            switch self {
            case .high:
                break
            case .medium:
                s.antiAliasing = 2
                s.shadows = .low
                s.drawDistance = 0.8
                s.plantDensity = 0.75
            case .low:
                s.antiAliasing = 1
                s.shadows = .off
                s.drawDistance = 0.6
                s.plantDensity = 0.5
                s.renderScale = .threeQuarters
            }
            return s
        }
    }

    /// The preset these settings are, or nil when a player has set them their own way.
    public var preset: Preset? { Preset.allCases.first { $0.settings == self } }

    // MARK: Ground cover

    /// **Whether copy `index` of a thinned kind is drawn at `density`.** The same copies at the same density every frame
    /// and every run — a hash of the index, not a random draw — so a meadow thins evenly and nothing flickers; and
    /// lowering the density only takes copies away, never swaps one for another.
    public static func keeps(_ index: Int, atDensity density: Float) -> Bool {
        guard density < 1 else { return true }
        // Fibonacci hashing: an index's fraction of the golden ratio, spread evenly over 0..<1.
        let f = Double(index) * 0.618_033_988_749_894_9
        return Float(f - f.rounded(.down)) < density
    }
}

extension FrameRenderer {
    /// **Applies what the engine draws with directly**: the sample count (as far as this device can) and the scene's
    /// scale, with `automatic` as the game's own choice. Shadows (a game's ``ShadowMap``), what is scattered and the
    /// frame rate (the display link) are the game's to apply — ``GraphicsSettings/Shadows/cascades(splits:lightDepthRange:)``
    /// and ``GraphicsSettings/frameRateRange`` say how. **Call it in `encodePrePasses`** or before a frame: the targets
    /// follow in the same frame. Rebuild every scene-pass pipeline when ``effectiveSampleCount`` changes.
    public func apply(_ settings: GraphicsSettings, automaticScaling: SceneScaling) {
        let s = settings.clamped
        sampleCount = supportsSampleCount(s.antiAliasing) ? s.antiAliasing : 1
        sceneScaling = s.renderScale.sceneScaling(automatic: automaticScaling)
    }
}
