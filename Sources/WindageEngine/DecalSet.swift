//
//  DecalSet.swift
//  WindageEngine
//

import simd

/// One mark on a surface: where, which way the surface faces, and which part of an atlas it shows.
public nonisolated struct Decal: Sendable, Equatable {
    /// Already lifted off the surface by the set's ``DecalSet/surfaceOffset``.
    public var position: SIMD3<Float>
    /// The surface it lies on, unit length. **A mark lies along its surface**, never facing the camera.
    public var normal: SIMD3<Float>
    /// Seconds since it was made.
    public var age: Float
    /// Meters across.
    public var size: Float
    /// The atlas cell it shows: (u0, v0, du, dv) — ``DecalAtlas/rect(column:row:)``.
    public var uvRect: SIMD4<Float>
    /// Multiplies the texel: rgb a tint, a an opacity. White and one draws the art as it was made.
    public var tint: SIMD4<Float>
}

/// A sheet of marks cut into equal cells, **columns across and rows down**.
public nonisolated struct DecalAtlas: Sendable, Equatable {
    public let columns: Int
    public let rows: Int

    public init(columns: Int, rows: Int) {
        self.columns = max(columns, 1)
        self.rows = max(rows, 1)
    }

    /// The whole texture as one cell.
    public static let whole = DecalAtlas(columns: 1, rows: 1)

    /// The cell to sample, (u0, v0, du, dv). Out-of-range indices are clamped onto the sheet, so a
    /// mark never samples past its edge.
    public func rect(column: Int, row: Int) -> SIMD4<Float> {
        let du = 1 / Float(columns), dv = 1 / Float(rows)
        let c = min(max(column, 0), columns - 1), r = min(max(row, 0), rows - 1)
        return SIMD4(Float(c) * du, Float(r) * dv, du, dv)
    }
}

/// **Marks left on surfaces**: bullet holes, scorches, footprints, splashes — the things a world keeps
/// for a while after something happened in it.
///
/// ### The simulation, not the drawing
///
/// Ages advance on the fixed step like everything else that matters, and the set is testable without
/// a GPU. ``DecalRenderer`` draws it. The same split as ``ParticleSystem`` and ``ParticleRenderer``.
///
/// ### Lifted, never coplanar
///
/// A mark exactly on its surface **z-fights** it — the two flicker against each other as the camera
/// moves, which reads as a rendering fault rather than as a mark. ``surfaceOffset`` lifts every mark
/// along its normal: large enough to clear depth precision at range, small enough not to float.
///
/// ### Kept for as long as a game says, then faded
///
/// ``holdSeconds`` at full strength, then ``fadeSeconds`` to nothing, then removed. A game whose marks
/// are information (where a shot landed) holds them long; one whose marks are garnish fades them fast.
/// **When the set is full the oldest mark goes**, never the newest — the newest is the one just made,
/// which is the one being looked at.
///
/// Taken from a sniper game's fall-of-shot marks (2026-10-27).
public nonisolated struct DecalSet: Sendable {

    /// How many marks are kept at once.
    public let capacity: Int
    /// Seconds a mark stays at full strength. Infinite keeps marks until ``clear()`` or the set fills.
    public var holdSeconds: Float
    /// Seconds a mark takes to fade once held. Zero removes it the moment its hold ends.
    public var fadeSeconds: Float
    /// Meters a mark is lifted off its surface.
    public var surfaceOffset: Float

    public private(set) var decals: [Decal] = []

    public init(capacity: Int = 256, holdSeconds: Float = .infinity, fadeSeconds: Float = 0,
                surfaceOffset: Float = 0.03) {
        self.capacity = max(capacity, 1)
        self.holdSeconds = holdSeconds
        self.fadeSeconds = fadeSeconds
        self.surfaceOffset = surfaceOffset
        decals.reserveCapacity(self.capacity)
    }

    public var count: Int { decals.count }

    /// 1 at full strength, 0 gone.
    public func opacity(of decal: Decal) -> Float {
        guard decal.age > holdSeconds else { return 1 }
        guard fadeSeconds > 0 else { return 0 }
        return max(0, 1 - (decal.age - holdSeconds) / fadeSeconds)
    }

    /// Ages every mark and removes the ones that have faded.
    public mutating func step(deltaTime: Float) {
        for index in decals.indices { decals[index].age += deltaTime }
        let hold = holdSeconds, fade = fadeSeconds
        decals.removeAll { $0.age > hold && (fade <= 0 || $0.age >= hold + fade) }
    }

    /// Leaves a mark.
    ///
    /// - Parameters:
    ///   - position: where it struck, **on** the surface — the set lifts it.
    ///   - normal: the surface's normal there. A zero normal is taken as up.
    ///   - size: meters across.
    ///   - uvRect: the atlas cell — ``DecalAtlas/rect(column:row:)``; the whole texture by default.
    ///   - tint: rgb multiplies the art, a its opacity.
    public mutating func mark(at position: SIMD3<Float>, normal: SIMD3<Float>, size: Float,
                              uvRect: SIMD4<Float> = SIMD4(0, 0, 1, 1),
                              tint: SIMD4<Float> = SIMD4(1, 1, 1, 1)) {
        let unit = simd_length_squared(normal) > 0 ? simd_normalize(normal) : SIMD3<Float>(0, 1, 0)
        let decal = Decal(position: position + unit * surfaceOffset, normal: unit, age: 0,
                          size: max(size, 0), uvRect: uvRect, tint: tint)
        if decals.count < capacity {
            decals.append(decal)
            return
        }
        // Full: the oldest goes. Every mark ages at the same rate, so the oldest is the eldest age.
        var oldest = 0
        for index in decals.indices where decals[index].age > decals[oldest].age { oldest = index }
        decals[oldest] = decal
    }

    /// Removes every mark — a new level, a new round, a new record.
    public mutating func clear() {
        decals.removeAll(keepingCapacity: true)
    }

    /// Two unit axes lying in a surface, for a mark's width and height.
    ///
    /// **Built from the normal rather than from the camera**, which is the whole difference between
    /// a decal and a billboard: aligned to the viewer, a mark stands up out of a hillside like a
    /// signpost.
    public static func basis(normal: SIMD3<Float>) -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        let n = simd_length_squared(normal) > 0 ? simd_normalize(normal) : SIMD3<Float>(0, 1, 0)
        let hint = abs(n.y) < 0.9 ? SIMD3<Float>(0, 1, 0) : SIMD3<Float>(1, 0, 0)
        let right = simd_normalize(simd_cross(hint, n))
        return (right, simd_cross(n, right))
    }
}
