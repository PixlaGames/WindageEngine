import Foundation
import Testing
import Metal
@testable import WindageEngine

struct GraphicsSettingsTests {
    @Test("The defaults are the game as made, and that is the High preset")
    func defaultsAreHigh() {
        let s = GraphicsSettings()
        #expect(s.preset == .high)
        #expect(s.shadows == .high && s.shadows.resolution == 2048)
        #expect(s.drawDistance == 1 && s.plantDensity == 1 && s.renderScale == .automatic && s.frameRate == 60)
        #expect(s.antiAliasing == 4)
        #expect(GraphicsSettings.Preset.medium.settings.antiAliasing == 2 && GraphicsSettings.Preset.low.settings.antiAliasing == 1)
    }

    @Test("Each preset reads back as itself; one changed setting makes it the player's own")
    func presetsRoundTrip() {
        for preset in GraphicsSettings.Preset.allCases { #expect(preset.settings.preset == preset) }
        var own = GraphicsSettings.Preset.medium.settings
        own.frameRate = 30
        #expect(own.preset == nil)
    }

    @Test("The settings in one line: a preset by name, a player's own value by value")
    func summary() {
        #expect(GraphicsSettings().summary == "High, 60 fps")
        var own = GraphicsSettings.Preset.medium.settings
        own.renderScale = .threeQuarters
        #expect(own.summary == "shadows low, draw 80%, ground cover 75%, scale ¾, 2× anti-aliasing, 60 fps")
    }

    @Test("Saved settings that ask for more or less than the screen offers are brought back in range")
    func clamped() {
        var s = GraphicsSettings()
        s.drawDistance = 3
        s.plantDensity = 0
        s.frameRate = 144
        let c = s.clamped
        #expect(c.drawDistance == 1 && c.plantDensity == 0.25 && c.frameRate == 60)
    }

    @Test("Settings survive being saved")
    func codable() throws {
        let s = GraphicsSettings.Preset.low.settings
        let back = try JSONDecoder().decode(GraphicsSettings.self, from: JSONEncoder().encode(s))
        #expect(back == s)
    }

    @Test("Settings saved before anti-aliasing existed still read, with it at its default")
    func olderSettingsRead() throws {
        let saved = #"{"shadows":"low","drawDistance":0.8,"plantDensity":0.75,"renderScale":"automatic","frameRate":30}"#
        let s = try JSONDecoder().decode(GraphicsSettings.self, from: Data(saved.utf8))
        #expect(s.shadows == .low && s.frameRate == 30 && s.antiAliasing == GraphicsSettings().antiAliasing)
    }

    @Test("A density keeps about that share, the same copies every time, and less density only takes copies away")
    func densityIsStableAndNested() {
        let n = 20_000
        for density: Float in [0.25, 0.5, 0.75] {
            let kept = (0..<n).filter { GraphicsSettings.keeps($0, atDensity: density) }.count
            #expect(abs(Float(kept) / Float(n) - density) < 0.01)
        }
        for i in 0..<n where GraphicsSettings.keeps(i, atDensity: 0.5) {
            #expect(GraphicsSettings.keeps(i, atDensity: 0.75))
        }
        #expect((0..<n).allSatisfy { GraphicsSettings.keeps($0, atDensity: 1) })
    }

    @Test("Each setting maps to what the engine draws with")
    func mapsToTheEngine() {
        let auto = SceneScaling.capped(width: 1920, beyond: 2600)
        #expect(GraphicsSettings.RenderScale.automatic.sceneScaling(automatic: auto) == auto)
        #expect(GraphicsSettings.RenderScale.full.sceneScaling(automatic: auto) == .native)
        #expect(GraphicsSettings.RenderScale.half.sceneScaling(automatic: auto) == .fraction(0.5))
        #expect(GraphicsSettings.Shadows.off.cascades(splits: [10, 40], lightDepthRange: 200) == nil)
        #expect(GraphicsSettings.Shadows.low.cascades(splits: [10, 40], lightDepthRange: 200)?.resolution == 1024)
        #expect(GraphicsSettings.Shadows.low.castingCascades(of: 4) == 3 && GraphicsSettings.Shadows.high.castingCascades(of: 4) == 4)
        #expect(GraphicsSettings.Shadows.low.castingCascades(of: 1) == 1)
        var thirty = GraphicsSettings()
        thirty.frameRate = 30
        #expect(thirty.frameRateRange.maximum == 30 && GraphicsSettings().frameRateRange.preferred == 60)
    }

    @Test("Applied to a frame renderer: the sample count as far as the device can, and the scale")
    @MainActor
    func appliedToTheRenderer() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let renderer = try FrameRenderer(device: device)
        renderer.apply(GraphicsSettings.Preset.low.settings, automaticScaling: .native)
        #expect(renderer.sampleCount == 1 && renderer.sceneScaling == .fraction(0.75))
        renderer.apply(GraphicsSettings(), automaticScaling: .capped(width: 1920, beyond: 2600))
        #expect(renderer.sampleCount == (device.supportsTextureSampleCount(4) ? 4 : 1))
        #expect(renderer.sceneScaling == .capped(width: 1920, beyond: 2600))
    }
}
