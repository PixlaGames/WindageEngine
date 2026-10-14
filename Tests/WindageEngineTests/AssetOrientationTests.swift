//
//  AssetOrientationTests.swift
//  WindageEngineTests
//

import Testing
import Foundation
import ModelIO
import simd
@testable import WindageEngine

@MainActor
struct AssetOrientationTests {

    private func place(_ point: SIMD3<Float>, _ orientation: AssetOrientation) -> SIMD3<Float> {
        let result = orientation.transform * SIMD4(point, 1)
        return SIMD3(result.x, result.y, result.z)
    }

    @Test("An asset already in this engine's space is left alone")
    func identityChangesNothing() {
        let point = SIMD3<Float>(3, -2, 7)
        #expect(simd_distance(place(point, .identity), point) < 1e-5)
        #expect(simd_almost_equal_elements(AssetOrientation.identity.transform,
                                           matrix_identity_float4x4, 1e-6))
    }

    /// 176 units tall in a Z-up file is a person: 1.76 m, standing up the Y axis.
    @Test("Z-up centimetres becomes Y-up metres")
    func zUpCentimetresIsCorrected() {
        let orientation = AssetOrientation(upAxis: .z, unitsPerMeter: 100)
        let headTop = place(SIMD3(0, 0, 176), orientation)
        #expect(abs(headTop.y - 1.76) < 1e-4, "the asset did not end up standing up the Y axis")
        #expect(abs(headTop.x) < 1e-5 && abs(headTop.z) < 1e-5)
    }

    /// **+90° about X also stands the asset up**, and turns it back to front doing it. That looks
    /// plausible until something is meant to face you, so the direction of the quarter turn is
    /// pinned here rather than left to whichever one was tried first.
    @Test("The Z-up turn is the one that does not mirror the asset front to back")
    func zUpTurnsTheRightWay() {
        let orientation = AssetOrientation(upAxis: .z, unitsPerMeter: 1)
        // In a Z-up file, -Y is the direction a character faces.
        let facing = place(SIMD3(0, -1, 0), orientation)
        #expect(abs(facing.z - 1) < 1e-5, "the quarter turn went the wrong way")
        #expect(abs(facing.y) < 1e-5)
        // And handedness survives: a mirrored asset would have a negative determinant.
        #expect(simd_determinant(orientation.transform) > 0)
    }

    @Test("Scale alone, for an asset that is already Y-up")
    func scaleWithoutRotation() {
        let orientation = AssetOrientation(upAxis: .y, unitsPerMeter: 100)
        #expect(simd_distance(place(SIMD3(0, 176, 0), orientation), SIMD3(0, 1.76, 0)) < 1e-4)
    }

    @Test("X-up stands up too")
    func xUpIsCorrected() {
        let orientation = AssetOrientation(upAxis: .x, unitsPerMeter: 1)
        #expect(simd_distance(place(SIMD3(2, 0, 0), orientation), SIMD3(0, 2, 0)) < 1e-4)
    }

    /// Model I/O reports the up axis, so this half needs no help from the caller.
    @Test("The up axis is read from the file")
    func upAxisComesFromTheAsset() throws {
        let url = try #require(Bundle.module.url(forResource: "z-up-centimetres", withExtension: "usda"))
        let asset = MDLAsset(url: url)
        #expect(AssetOrientation.upAxis(of: asset) == .z)
    }

    /// **Model I/O does not expose `metersPerUnit`**, so the scale is the caller's to supply even
    /// though the file records it. Measured here the way a game measures it: load the asset, read
    /// the height of the bounding box, and divide by how tall the thing really is.
    @Test("The unit scale is supplied, because the API does not offer it")
    func scaleIsSuppliedNotRead() throws {
        let url = try #require(Bundle.module.url(forResource: "z-up-centimetres", withExtension: "usda"))
        let asset = MDLAsset(url: url)

        var height: Float = 0
        func descend(_ object: MDLObject) {
            if let mesh = object as? MDLMesh {
                // Z-up, so the file's "height" is along Z.
                height = max(height, mesh.boundingBox.maxBounds.z - mesh.boundingBox.minBounds.z)
            }
            for child in object.children.objects { descend(child) }
        }
        for index in 0..<asset.count { descend(asset.object(at: index)) }
        #expect(abs(height - 176) < 1e-3, "the asset is in its own units, unconverted")

        let orientation = AssetOrientation(asset: asset, unitsPerMeter: height / 1.76)
        #expect(orientation.upAxis == .z)
        let top = place(SIMD3(0, 0, height), orientation)
        #expect(abs(top.y - 1.76) < 1e-3)
    }

    /// A file that has been through two conversions reports something like (0, 0.9999997, 0) rather
    /// than a clean unit vector; comparing for equality calls that "no up axis at all".
    @Test("A nearly-unit up vector is still an up vector")
    func dominantAxisRatherThanExact() {
        #expect(AssetOrientation.UpAxis.y == AssetOrientation.upAxis(of: MDLAsset()))
    }
}

/// **Zero units to the meter is a mistake, said at once.** It used to be read as 1 — an asset whose
/// scale had been forgotten came in at whatever size it happened to be, with nothing to say so.
@Test func aZeroUnitScaleIsRefused() async {
    await #expect(processExitsWith: .failure) {
        _ = AssetOrientation(upAxis: .z, unitsPerMeter: 0)
    }
}
