//
//  InterfaceColor.swift
//  WindageEngine
//

import simd

/// A color authored for the **interface**, not for the scene.
///
/// **The distinction this type exists to make explicit.** Scene colors are radiance: unbounded,
/// linear, and tone mapped on the way to the screen — a scene color of `#00C2FF` will not arrive as
/// `#00C2FF`, because an exposure and a filmic curve stand between it and the drawable, by design.
/// Interface colors are the opposite: they are a *specification*, and a brand cyan must land on the
/// screen as exactly that cyan.
///
/// So an `InterfaceColor` is authored in sRGB (the space hex codes live in) and converted to linear once,
/// here. The drawable is an `_srgb` format, so the GPU re-encodes on write and the value round-trips
/// exactly — provided the interface is drawn **after** tone mapping. `HUDRenderer` is what makes
/// that ordering structural rather than something each title has to remember.
///
/// > Named `UIColor` until the 1.0 API audit, which collided with UIKit's the moment a file imported
/// > it — and would have blocked an iPad or iOS target outright.
public nonisolated struct InterfaceColor: Sendable, Equatable {

    /// As authored, sRGB-encoded, 0...1 per channel.
    public let srgb: SIMD4<Float>

    /// What the shader writes. Linear, so the `_srgb` drawable encodes back to ``srgb`` exactly.
    public let linear: SIMD4<Float>

    public init(srgb: SIMD4<Float>) {
        self.srgb = srgb
        self.linear = SIMD4(InterfaceColor.toLinear(srgb.x),
                            InterfaceColor.toLinear(srgb.y),
                            InterfaceColor.toLinear(srgb.z),
                            srgb.w)   // alpha is not gamma-encoded
    }

    /// From a hex literal, the way brand colors are actually written down: `InterfaceColor(hex: 0x00C2FF)`.
    public init(hex: UInt32, alpha: Float = 1) {
        self.init(srgb: SIMD4(Float((hex >> 16) & 0xFF) / 255,
                              Float((hex >> 8) & 0xFF) / 255,
                              Float(hex & 0xFF) / 255,
                              alpha))
    }

    public func withAlpha(_ alpha: Float) -> InterfaceColor {
        InterfaceColor(srgb: SIMD4(srgb.x, srgb.y, srgb.z, alpha))
    }

    /// The real sRGB transfer function, not a 2.2 approximation. The two differ most in the darks,
    /// which is exactly where a HUD's translucent panels live.
    static func toLinear(_ channel: Float) -> Float {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    public static let clear = InterfaceColor(srgb: .zero)
    public static let white = InterfaceColor(hex: 0xFFFFFF)
    public static let black = InterfaceColor(hex: 0x000000)
}
