//
//  Instancing.swift
//  WindageEngine
//

import Foundation
import Metal
import simd

/// Many copies of the same meshes, grouped so each mesh is drawn once with an instance count.
///
/// **Why an engine has this.** A wood is a few hundred trees of two or three kinds; a rubble field is
/// a hundred stones of one. Drawn as objects, that is a draw call per copy per submesh — the CPU cost
/// grows with the copies, and it is what stops a scene growing past one valley. Drawn instanced, it is
/// one draw per submesh per *kind*, and the copies are a buffer of transforms the GPU indexes.
///
/// **The CPU half, split from the GPU half the way ``ParticleSystem`` is from ``ParticleRenderer``.**
/// Grouping has an order to get right and offsets to get right, and both are wrong silently — a copy
/// drawn with the next kind's transform, or a frame whose draws come out in a different order from the
/// last. That half is tested here without a GPU; ``InstanceBuffer`` only puts the result where a shader
/// can read it.
///
/// ### Order is fixed, on purpose
///
/// **Kinds come in the order they were first seen, and copies in the order they were given.** A
/// dictionary's order would change between runs, and with it which kind is drawn first — invisible in
/// an opaque pass, and a flicker the day a transparent kind is instanced.
public nonisolated struct InstanceBatches<Key: Hashable & Sendable>: Sendable {

    /// One kind's run of transforms.
    public struct Batch: Sendable, Equatable {
        public let key: Key
        /// Index of this kind's first transform in ``InstanceBatches/transforms``.
        public let start: Int
        public let count: Int

        /// Where this kind's transforms start in a buffer written from ``InstanceBatches/transforms``:
        /// bind the buffer's address plus this, and index it with `[[instance_id]]`.
        public var byteOffset: Int { start * MemoryLayout<simd_float4x4>.stride }
    }

    /// Every copy's transform, kind after kind, each kind's copies together.
    public private(set) var transforms: [simd_float4x4] = []
    public private(set) var batches: [Batch] = []

    public init() {}

    /// Groups copies by kind.
    public init<Copies: Sequence>(_ copies: Copies) where Copies.Element == (Key, simd_float4x4) {
        var order: [Key] = []
        var grouped: [Key: [simd_float4x4]] = [:]
        for (key, transform) in copies {
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(transform)
        }
        for key in order {
            let run = grouped[key]!
            batches.append(Batch(key: key, start: transforms.count, count: run.count))
            transforms.append(contentsOf: run)
        }
    }

    public var isEmpty: Bool { transforms.isEmpty }
}

/// The GPU half: a frame's instance transforms, in a buffer a vertex shader indexes with
/// `[[instance_id]]`.
///
/// **One buffer per frame in flight**, because a frame still being drawn is reading the last one —
/// rewriting it in place draws a copy at the next frame's position for a frame, which is a flicker
/// nobody can explain. **Grown, never shrunk**, and with room to spare when it grows, so a scene that
/// is being added to — a brush stroke laying down copies every tick — does not reallocate every frame.
///
/// The engine draws nothing here: the vertex function is the game's, because the vertices are. The
/// contract is one `float4x4` per copy, at the batch's ``InstanceBatches/Batch/byteOffset``, applied
/// on top of whatever per-object transform the game already has.
public final class InstanceBuffer {

    private let renderer: FrameRenderer
    private var buffers: [MTLBuffer?]

    /// The smallest buffer made, in copies — a few kilobytes, so a scene with a handful does not grow it.
    nonisolated static let minimumCapacity = 1024

    public init(renderer: FrameRenderer) {
        self.renderer = renderer
        self.buffers = Array(repeating: nil, count: FrameRenderer.maxFramesInFlight)
    }

    /// How many copies a buffer should hold for `needed`, given it holds `current` now: unchanged when
    /// it fits, else half as much again as needed, and never below ``minimumCapacity``.
    nonisolated static func capacity(for needed: Int, current: Int) -> Int {
        if needed <= current { return current }
        return max(needed + needed / 2, minimumCapacity)
    }

    /// Writes this frame's transforms and returns the buffer they are in, or `nil` when there are none.
    ///
    /// Growing the buffer adds the new one to the renderer's residency set and commits it, and takes the
    /// old one out — a buffer the GPU cannot reach is not a missing draw, it is garbage on screen.
    public func write<Key>(_ batches: InstanceBatches<Key>, frameSlot: Int) -> MTLBuffer? {
        guard !batches.isEmpty else { return nil }
        let slot = frameSlot % buffers.count
        let stride = MemoryLayout<simd_float4x4>.stride
        let current = (buffers[slot]?.length ?? 0) / stride
        let wanted = Self.capacity(for: batches.transforms.count, current: current)
        if wanted != current || buffers[slot] == nil {
            guard let buffer = renderer.device.makeBuffer(length: wanted * stride, options: .storageModeShared)
            else { return nil }
            buffer.label = "Instance Transforms \(slot)"
            if let old = buffers[slot] { renderer.residencySet.removeAllocation(old) }
            renderer.residencySet.addAllocation(buffer)
            renderer.commitResidency()
            buffers[slot] = buffer
        }
        let buffer = buffers[slot]!
        batches.transforms.withUnsafeBytes { source in
            buffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        return buffer
    }
}
