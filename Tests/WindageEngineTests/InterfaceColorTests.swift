//
//  InterfaceColorTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

/// Guards the conversion that makes a brand colour survive the journey to the screen.
///
/// The drawable is an `_srgb` format, so the GPU encodes linear values back to sRGB on write. A
/// `InterfaceColor` therefore round-trips **exactly** — verified on-device by reading pixels back: an
/// authored `#00C2FF` arrives as `#00C2FF`. These tests pin the CPU half of that, which is the half
/// that can be checked without a GPU.
struct InterfaceColorTests {

    /// The GPU's side of the round trip: linear back to sRGB.
    private func encode(_ channel: Float) -> Float {
        channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
    }

    @Test("Hex parses to the channels it names")
    func hexParses() {
        let cyan = InterfaceColor(hex: 0x00C2FF)
        #expect(cyan.srgb.x == 0)
        #expect(abs(cyan.srgb.y - 194.0 / 255.0) < 1e-6)
        #expect(abs(cyan.srgb.z - 1.0) < 1e-6)
        #expect(cyan.srgb.w == 1)
    }

    /// The property the whole type exists for.
    @Test("Authored colour survives the trip to the screen and back")
    func roundTripsExactly() {
        for hex: UInt32 in [0x00C2FF, 0xFF8C3B, 0x007499, 0x000000, 0xFFFFFF, 0x0B1016] {
            let color = InterfaceColor(hex: hex)
            let returned = SIMD3(encode(color.linear.x), encode(color.linear.y), encode(color.linear.z))
            let authored = SIMD3(color.srgb.x, color.srgb.y, color.srgb.z)
            #expect(simd_length(returned - authored) < 1e-5,
                    "hex \(String(hex, radix: 16)) did not survive the round trip")
        }
    }

    /// Alpha is coverage, not light. Gamma-encoding it makes every translucent panel the wrong
    /// density — subtly, and consistently in the same direction, which is the hardest kind to spot.
    @Test("Alpha is not gamma-encoded")
    func alphaIsLinear() {
        let half = InterfaceColor(hex: 0x00C2FF, alpha: 0.5)
        #expect(half.srgb.w == 0.5)
        #expect(half.linear.w == 0.5)
    }

    /// The real transfer function, not a 2.2 approximation. They differ most in the darks, which is
    /// exactly where translucent HUD panels live.
    @Test("Dark channels use the linear segment, not a power curve")
    func darksUseTheLinearSegment() {
        // Below the 0.04045 knee the curve is a straight division by 12.92.
        let dark = InterfaceColor(srgb: SIMD4(0.02, 0.02, 0.02, 1))
        #expect(abs(dark.linear.x - 0.02 / 12.92) < 1e-9)

        // A 2.2 power curve would give a visibly different answer here.
        #expect(abs(dark.linear.x - pow(0.02, 2.2)) > 1e-5)
    }

    @Test("Black and white are exact")
    func extremesAreExact() {
        #expect(InterfaceColor.black.linear.x == 0)
        #expect(abs(InterfaceColor.white.linear.x - 1) < 1e-6)
    }

    @Test("withAlpha keeps the hue")
    func alphaAdjustmentKeepsHue() {
        let base = InterfaceColor(hex: 0xFF8C3B)
        let faded = base.withAlpha(0.25)
        #expect(faded.srgb.x == base.srgb.x)
        #expect(faded.linear.y == base.linear.y)
        #expect(faded.srgb.w == 0.25)
    }
}
