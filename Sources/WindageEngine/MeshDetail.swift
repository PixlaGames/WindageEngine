//
//  MeshDetail.swift
//  WindageEngine
//

import Foundation
import MeshOptimizer
import MetalKit
import simd

/// Level of detail: simpler versions of a mesh, made when it loads, and the rule that picks one for how far
/// away a copy stands.
///
/// **Why an engine has this.** A scene of a few hundred trees is fine; a valley of thousands is not, and most
/// of their triangles are detail too small to see from where they stand. Asset packs rarely ship their own
/// simpler meshes, so the engine makes them — with **meshoptimizer's simplifier** (MIT, vendored unmodified
/// as the `MeshOptimizer` target; **an app that uses this ships its license**, `Sources/MeshOptimizer/LICENSE.md`).
///
/// A mesh gets up to ten **tiers**, each about half the triangles of the one before; tier 0 is the mesh as
/// loaded. ("Tier" rather than "level", which in this engine is a ``Level`` file.) Each tier carries its own
/// vertices, with normals made again from its own faces.
///
/// **A tier is chosen by how far its shape strays, measured on screen.** The simplifier reports how far each
/// tier's surface moved from the original, in the mesh's units; seen from far enough away that distance is
/// under half a pixel, and the tier cannot be told from the full mesh. So the rule is not a table of distances
/// to tune per asset — a tree and a pebble each switch when their own error shrinks far enough. **Half a pixel,
/// not one**: at one, a wood of trees six pixels tall visibly lost their tiers of branches — a pixel of error
/// all round an outline that small adds up to a different shape.
///
/// **The CPU half only**, like ``InstanceBatches``: making tiers and choosing one need no GPU and are tested
/// here. Putting a tier in a buffer and drawing it is the game's, because only the game knows its vertex layout
/// and how it batches. Copies at different tiers are different batches — key ``InstanceBatches`` by mesh *and*
/// tier.
///
/// > Extracted 2026-10-12 from a world editor's scattered woods, where 1,000 trees of 19,000 triangles each
/// > went from 25 ms a frame to 5.6 ms on an M2 (after culling per pass; 75 ms before either).
public nonisolated enum MeshDetail {
    /// One simplified version of one submesh.
    public struct Reduction: Sendable, Equatable {
        /// Triangles, as indices into the full mesh's vertices.
        public let indices: [UInt32]
        /// How far, in the mesh's own units, this surface strays from the full mesh at most.
        public let error: Float
    }

    /// How tiers are made. The defaults are what the engine was measured with; a game changes one when
    /// its own meshes ask for it.
    public struct Options: Sendable, Equatable {
        /// Each tier aims for this share of the triangles of the one before it.
        public let reduction: Float
        /// At most this many tiers below the full mesh.
        public let maximumTiers: Int
        /// Tiers stop when one keeps more than this share of the triangles before it — the simplifier has
        /// met the mesh's limit, and another tier would cost memory to save nothing.
        public let stall: Float
        /// Faces meeting at more than this angle keep a hard edge between them in a tier's normals: cos 60°.
        public let creaseCosine: Float
        /// Fewer triangles than this are not worth simplifying further.
        public let smallestTriangleCount: Int

        public init(reduction: Float = 0.5, maximumTiers: Int = 10, stall: Float = 0.85,
                    creaseCosine: Float = 0.5, smallestTriangleCount: Int = 12) {
            precondition(reduction > 0 && reduction < 1, "Each tier must keep a share of the last, between 0 and 1")
            precondition(maximumTiers >= 0, "A mesh cannot have fewer than no tiers")
            precondition(stall > 0 && stall <= 1, "The stall share must be in 0…1")
            precondition(smallestTriangleCount >= 1, "The smallest mesh worth simplifying has a triangle")
            self.reduction = reduction
            self.maximumTiers = maximumTiers
            self.stall = stall
            self.creaseCosine = creaseCosine
            self.smallestTriangleCount = smallestTriangleCount
        }

        /// What the engine was measured with.
        public static let standard = Options()
    }

    /// Simplified versions of one submesh: coarser and coarser, each with its error. Empty when the submesh is
    /// already too small to simplify, or the simplifier could not reduce it.
    ///
    /// `positions` points at the first vertex's position — three floats — and vertices are `stride` bytes apart.
    public static func reductions(indices: [UInt32], positions: UnsafeRawPointer, vertexCount: Int, stride: Int,
                                  options: Options = .standard) -> [Reduction] {
        guard indices.count / 3 > options.smallestTriangleCount, vertexCount > 0 else { return [] }
        var reductions: [Reduction] = []
        var previous = indices.count
        var target = Float(indices.count)
        // **Permissive**: collapses may cross a hard edge. Low-poly packs split every vertex at every hard edge,
        // so a careful simplifier finds nothing it may touch; the cost is softened shading on a far copy,
        // which the error rule keeps below half a pixel. **Sparse**, because a submesh is a subset of its mesh's
        // vertices. **Absolute**, so the error comes back in the mesh's units.
        let flags = UInt32(meshopt_SimplifyPermissive | meshopt_SimplifySparse | meshopt_SimplifyErrorAbsolute)
        var destination = [UInt32](repeating: 0, count: indices.count)
        for _ in 0..<options.maximumTiers {
            target *= options.reduction
            let wanted = max(Int(target) / 3 * 3, 3)
            var error: Float = 0
            // Always from the full mesh, never from the last one: errors do not add up from tier to tier.
            let count = indices.withUnsafeBufferPointer { source in
                destination.withUnsafeMutableBufferPointer { out in
                    meshopt_simplify(out.baseAddress, source.baseAddress, source.count,
                                     positions.assumingMemoryBound(to: Float.self), vertexCount, stride,
                                     wanted, .greatestFiniteMagnitude, flags, &error)
                }
            }
            guard count >= 3, Float(count) < Float(previous) * options.stall else { break }
            reductions.append(Reduction(indices: Array(destination[0..<count]), error: error))
            previous = count
            if count / 3 <= options.smallestTriangleCount { break }
        }
        return reductions
    }

    /// The coarsest tier whose error, at this distance, covers less than `maximumPixelError` on screen. 0 is
    /// the full mesh; `errors[i]` is tier `i + 1`'s — its ``Tier/error``.
    ///
    /// - `distance`: from the eye to the nearest the copy can come — its box's center less its radius.
    /// - `scale`: the copy's size; a tree scaled up strays further.
    /// - `pixelsPerRadian`: the viewport's height in pixels over its vertical field of view, near enough for
    ///   the small angles a tier's error makes.
    public static func coarsestTier(errors: [Float], distance: Float, scale: Float, pixelsPerRadian: Float,
                                    maximumPixelError pixels: Float = 0.5) -> Int {
        guard distance > 0 else { return 0 }
        var chosen = 0
        for (index, error) in errors.enumerated() {
            guard error * scale / distance * pixelsPerRadian < pixels else { break }
            chosen = index + 1
        }
        return chosen
    }

    /// One tier of a whole mesh, ready to draw: its own vertices and every submesh's triangles into them.
    public struct Tier: Sendable, Equatable {
        /// Vertices in the full mesh's layout, `stride` bytes each — three per triangle.
        public let vertices: [UInt8]
        /// Per submesh, indices into `vertices`.
        public let submeshes: [[UInt32]]
        /// The worst of its submeshes' errors, in the mesh's units. Tier `i` of a mesh is reduction `i` of every
        /// submesh, so a copy changes all its parts at once; a submesh with fewer reductions repeats its coarsest.
        public let error: Float
    }

    /// A mesh's tiers, each with **its own vertices and normals made again from its own triangles.**
    ///
    /// A simplified mesh keeps some of the full mesh's vertices and drops the rest, and a kept vertex keeps its
    /// normal. On a faceted prop that normal belonged to one face of many — perhaps one facing the ground — so a
    /// far copy drew nearly black. Recomputed from the tier's own faces, the light is right for the surface
    /// actually drawn; the cost is three vertices per triangle of each tier, which halves with every tier —
    /// about 1 MB for every tier of a 19,000-triangle tree together.
    ///
    /// - `full`: each submesh's own indices, for a submesh with no reductions of its own.
    /// - `vertices`: the first vertex — its first byte, not its position.
    /// - `positionOffset`, `normalOffset`: bytes into a vertex where its position's and its normal's three
    ///   floats are.
    public static func tiers(_ reductions: [[Reduction]], full: [[UInt32]], vertices: UnsafeRawPointer,
                             stride: Int, positionOffset: Int, normalOffset: Int,
                             options: Options = .standard) -> [Tier] {
        let count = reductions.map(\.count).max() ?? 0
        return (0..<count).map { tier in
            let chosen = reductions.indices.map { submesh -> (indices: [UInt32], error: Float) in
                let own = reductions[submesh]
                guard !own.isEmpty else { return (full[submesh], 0) }
                let picked = own[min(tier, own.count - 1)]
                return (picked.indices, picked.error)
            }
            // **Every corner its own vertex**, its normal the average of the faces meeting at its position that
            // bend less than the crease angle from its own face. Averaging by position, not by vertex, is what
            // makes it robust: a faceted prop keeps its vertices split even after simplifying, so a vertex's own
            // faces can be a single sliver standing edge-on — and its neighbours outvote it here. Hard edges
            // stay hard, because a face across a crease is not counted.
            func position(_ old: UInt32) -> SIMD3<Float> {
                let p = (vertices + Int(old) * stride + positionOffset).assumingMemoryBound(to: Float.self)
                return SIMD3(p[0], p[1], p[2])
            }
            var faces: [(normal: SIMD3<Float>, area: SIMD3<Float>)] = []   // unit normal, area-weighted normal
            var atPosition: [SIMD3<Float>: [Int]] = [:]
            for part in chosen {
                for t in Swift.stride(from: 0, to: part.indices.count - 2, by: 3) {
                    let a = position(part.indices[t]), b = position(part.indices[t + 1])
                    let c = position(part.indices[t + 2])
                    let cross = simd_cross(b - a, c - a)
                    let length = simd_length(cross)
                    faces.append((length > 0 ? cross / length : .zero, cross))
                    for p in [a, b, c] { atPosition[p, default: []].append(faces.count - 1) }
                }
            }
            let corners = chosen.reduce(0) { $0 + $1.indices.count / 3 * 3 }
            var bytes = [UInt8](repeating: 0, count: corners * stride)
            var submeshes: [[UInt32]] = []
            var face = 0, corner = 0
            bytes.withUnsafeMutableBytes { out in
                for part in chosen {
                    var renumbered: [UInt32] = []
                    for t in Swift.stride(from: 0, to: part.indices.count - 2, by: 3) {
                        for k in 0..<3 {
                            let old = part.indices[t + k]
                            let around = atPosition[position(old)] ?? []
                            let own = faces[face].normal
                            let target = out.baseAddress! + corner * stride
                            target.copyMemory(from: vertices + Int(old) * stride, byteCount: stride)
                            var sum = SIMD3<Float>.zero
                            for other in around where simd_dot(faces[other].normal, own) >= options.creaseCosine {
                                sum += faces[other].area
                            }
                            let length = simd_length(sum)
                            // A corner only on faces of no area keeps the normal it had.
                            if length > 0 {
                                let n = sum / length
                                let normal = (target + normalOffset).assumingMemoryBound(to: Float.self)
                                normal[0] = n.x; normal[1] = n.y; normal[2] = n.z
                            }
                            renumbered.append(UInt32(corner))
                            corner += 1
                        }
                        face += 1
                    }
                    submeshes.append(renumbered)
                }
            }
            return Tier(vertices: bytes, submeshes: submeshes, error: chosen.map(\.error).max() ?? 0)
        }
    }

    /// Tiers for a mesh ``MeshLoader`` loaded, read from its own buffers — which Model I/O's Metal allocator makes
    /// shared, so CPU-readable, on Apple silicon. Empty for a mesh with a submesh that is not triangles.
    ///
    /// `vertexDescriptor` is the one the mesh was loaded with. Attributes `positionAttribute` and
    /// `normalAttribute` say where each vertex's position is read from and where the normal each tier
    /// rewrites goes; both must be in the same buffer, whose layout gives the stride. Safe off the main
    /// thread, and worth running there: simplifying a 19,000-triangle mesh takes a few milliseconds.
    public static func tiers(for mesh: LoadedMesh, vertexDescriptor: MTLVertexDescriptor,
                             positionAttribute: Int, normalAttribute: Int,
                             options: Options = .standard) -> [Tier] {
        let position: MTLVertexAttributeDescriptor = vertexDescriptor.attributes[positionAttribute]
        let normal: MTLVertexAttributeDescriptor = vertexDescriptor.attributes[normalAttribute]
        precondition(position.format == .float3 && normal.format == .float3,
                     "MeshDetail reads positions and normals as three floats")
        precondition(position.bufferIndex == normal.bufferIndex,
                     "MeshDetail needs a vertex's position and normal in the same buffer")
        let bufferIndex = position.bufferIndex
        guard mesh.mesh.vertexBuffers.indices.contains(bufferIndex),
              mesh.mesh.submeshes.allSatisfy({ $0.primitiveType == .triangle }) else { return [] }
        let vertices = mesh.mesh.vertexBuffers[bufferIndex]
        let start = UnsafeRawPointer(vertices.buffer.contents() + vertices.offset)
        let vertexCount = mesh.mesh.vertexCount
        let stride = vertexDescriptor.layouts[bufferIndex].stride
        let full = mesh.mesh.submeshes.map { submesh -> [UInt32] in
            let source = submesh.indexBuffer.buffer.contents() + submesh.indexBuffer.offset
            return submesh.indexType == .uint32
                ? Array(UnsafeBufferPointer(start: source.assumingMemoryBound(to: UInt32.self), count: submesh.indexCount))
                : UnsafeBufferPointer(start: source.assumingMemoryBound(to: UInt16.self), count: submesh.indexCount)
                    .map(UInt32.init)
        }
        let reduced = full.map {
            reductions(indices: $0, positions: start + position.offset, vertexCount: vertexCount, stride: stride,
                       options: options)
        }
        return tiers(reduced, full: full, vertices: start, stride: stride, positionOffset: position.offset,
                     normalOffset: normal.offset, options: options)
    }
}
