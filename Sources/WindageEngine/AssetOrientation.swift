//
//  AssetOrientation.swift
//  WindageEngine
//

import Foundation
import ModelIO
import simd

/// What space an asset was authored in, and the one matrix that brings it into this engine's.
///
/// **This engine is Y-up and works in meters.** Almost nothing else agrees. A character coming out of
/// a game-engine toolchain by way of Blender arrives **Z-up and in centimeters** — 176 units tall for
/// a person — and neither fact is a mistake anybody made. They are the conventions of the tools it
/// passed through.
///
/// ### Why this is a matrix and not a conversion pass
///
/// It would be possible to rewrite every vertex on load. It would also be wrong: a skinned character
/// has its geometry, its **bind transforms** and its **clip translations** all in the same space, so
/// converting the mesh alone leaves the skeleton a hundred times too big and the animation a hundred
/// times too fast in space. Converting all three means touching three different representations and
/// getting all three right.
///
/// Skinning happens in model space and the model matrix takes that to the world, so **one matrix in
/// front of the model matrix corrects the mesh, the rig and the animation together**, for free, and
/// nothing downstream has to know.
///
/// ### The unit scale has to be supplied, and that is Model I/O's gap rather than a choice
///
/// USD records `metersPerUnit` in the file. **Model I/O does not expose it** — `MDLAsset` surfaces
/// `upAxis` and nothing about units — so the up axis can be read and the scale cannot. Measure the
/// asset once and write the number down beside it.
///
/// > **Facing is deliberately not here.** Which way is "forward" varies per tool *and* per rig, and
/// > guessing it means every asset that disagrees is silently backwards. It is a yaw the game applies
/// > where it places the thing, which is somewhere it already has to think about.
public nonisolated struct AssetOrientation: Sendable, Equatable {

    public enum UpAxis: Sendable, Equatable {
        case x, y, z
    }

    /// Which axis the asset treats as up.
    public var upAxis: UpAxis

    /// How many of the asset's units make a meter — 1 for an asset already in meters, 100 for one in
    /// centimeters. Positive and finite: zero would scale the asset to nothing, and is a mistake to say
    /// at once rather than to correct quietly.
    public var unitsPerMeter: Float {
        didSet { AssetOrientation.check(unitsPerMeter) }
    }

    /// An asset already in this engine's space: Y-up, meters.
    public static let identity = AssetOrientation()

    public init(upAxis: UpAxis = .y, unitsPerMeter: Float = 1) {
        AssetOrientation.check(unitsPerMeter)
        self.upAxis = upAxis
        self.unitsPerMeter = unitsPerMeter
    }

    private static func check(_ unitsPerMeter: Float) {
        precondition(unitsPerMeter > 0 && unitsPerMeter.isFinite,
                     "unitsPerMeter must be positive and finite, not \(unitsPerMeter)")
    }

    /// The correction, to be applied **before** the model matrix that places the object:
    /// `model * orientation.transform`.
    public var transform: simd_float4x4 {
        let scale = 1 / unitsPerMeter
        var result = rotation
        // Uniform, so it commutes with the rotation and can simply scale the basis columns.
        result.columns.0 *= scale
        result.columns.1 *= scale
        result.columns.2 *= scale
        return result
    }

    /// Just the axis change, without the scale.
    public var rotation: simd_float4x4 {
        switch upAxis {
        case .y:
            return matrix_identity_float4x4
        case .z:
            // Z-up to Y-up, both right-handed: (x, y, z) becomes (x, z, -y), which is a quarter turn
            // of -90° about X. **Not +90°** — that flips the asset front to back as well as
            // standing it up, and the result looks plausible until something is meant to face you.
            return simd_float4x4(rotationAngle: -.pi / 2, axis: SIMD3(1, 0, 0))
        case .x:
            // X-up to Y-up: (x, y, z) becomes (-y, x, z).
            return simd_float4x4(rotationAngle: .pi / 2, axis: SIMD3(0, 0, 1))
        }
    }

    /// Reads the up axis Model I/O reports, and takes the scale on trust from the caller.
    ///
    /// - Parameter unitsPerMeter: measure it once — load the asset, read the height of its bounding
    ///   box, and divide by how tall the thing actually is. A person is about 1.75 m.
    public init(asset: MDLAsset, unitsPerMeter: Float = 1) {
        self.init(upAxis: AssetOrientation.upAxis(of: asset), unitsPerMeter: unitsPerMeter)
    }

    /// The dominant axis of the asset's up vector.
    ///
    /// **Dominant rather than exact.** `upAxis` is a float vector, and a file that has been through
    /// two conversions can report (0, 0.9999997, 0) rather than a clean unit vector; comparing for
    /// equality would call that "no up axis at all".
    public static func upAxis(of asset: MDLAsset) -> UpAxis {
        let up = asset.upAxis
        let magnitudes = SIMD3(abs(up.x), abs(up.y), abs(up.z))
        if magnitudes.z > magnitudes.x && magnitudes.z > magnitudes.y { return .z }
        if magnitudes.x > magnitudes.y && magnitudes.x > magnitudes.z { return .x }
        return .y
    }
}
