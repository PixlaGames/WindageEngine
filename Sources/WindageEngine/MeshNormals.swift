//
//  MeshNormals.swift
//  WindageEngine
//

import Foundation
import ModelIO
import simd

/// **Normals for a mesh that arrives without them**, made from its shape.
///
/// ### Why a file's normals can go missing
///
/// **Model I/O drops the normals of a USD mesh whose blend shapes are bound** — a character's face, brows, teeth and
/// tongue as a character creator exports them, each carrying the shapes a face is animated with. The positions, texture
/// coordinates, colours and skin come through; the normals do not, in any form they can be written in (per vertex, per
/// corner, as a primvar, with the shapes' own normal offsets). Converted to a game's layout, the missing attribute is
/// filled with one constant, and every such part is lit as one flat card: a face seen from the front loses its nose and
/// mouth, while its profile still shows against what is behind it.
///
/// ### How they are made
///
/// Each vertex takes the sum of the triangles around it, **each weighted by its angle at that vertex** — so a vertex's
/// normal does not lean toward whichever side happens to be cut into more triangles — **shared by every vertex at the
/// same position**: a part's vertices are split where its texture layout is, and a crease there would draw a seam the
/// model does not have. Within one mesh only; two parts meeting at a seam each smooth up to it.
///
/// They are not the file's: an artist's normals are often edited for a softer look, and that cannot be recovered from
/// the shape. They are what the shape says, which lights a face as a face.
nonisolated enum MeshNormals {

    /// Gives `mesh` smooth normals if it has none. Returns whether it did.
    @discardableResult
    static func addIfMissing(to mesh: MDLMesh) -> Bool {
        let attributes = (mesh.vertexDescriptor.attributes as? [MDLVertexAttribute] ?? []).filter { $0.format != .invalid }
        guard !attributes.contains(where: { $0.name == MDLVertexAttributeNormal }),
              let data = mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributePosition, as: .float3) else {
            return false
        }
        let positions = (0..<mesh.vertexCount).map { vertex in
            data.dataStart.advanced(by: vertex * data.stride).loadUnaligned(as: (Float, Float, Float).self)
        }.map { SIMD3($0.0, $0.1, $0.2) }

        var triangles: [UInt32] = []
        for submesh in mesh.submeshes as? [MDLSubmesh] ?? [] where submesh.geometryType == .triangles {
            let map = submesh.indexBuffer(asIndexType: .uInt32).map()
            triangles += (0..<submesh.indexCount).map { map.bytes.advanced(by: $0 * 4).loadUnaligned(as: UInt32.self) }
            withExtendedLifetime(map) {}
        }

        let normals = smooth(positions: positions, triangles: triangles)
        let bytes = normals.flatMap { [$0.x, $0.y, $0.z] }.withUnsafeBytes { Data($0) }
        mesh.addAttribute(withName: MDLVertexAttributeNormal, format: .float3, type: MDLVertexAttributeNormal,
                          data: bytes, stride: MemoryLayout<Float>.stride * 3)
        return true
    }

    /// Angle-weighted normals, one a vertex, shared by vertices at the same position. A vertex in no triangle, or only in
    /// ones with no area, points up.
    static func smooth(positions: [SIMD3<Float>], triangles: [UInt32]) -> [SIMD3<Float>] {
        var sums: [SIMD3<Float>: SIMD3<Float>] = [:]
        for t in stride(from: 0, to: triangles.count - 2, by: 3) {
            let corners = (0..<3).map { Int(triangles[t + $0]) }
            guard corners.allSatisfy({ $0 < positions.count }) else { continue }
            let p = corners.map { positions[$0] }
            let face = cross(p[1] - p[0], p[2] - p[0])
            guard length_squared(face) > 0 else { continue }
            let normal = normalize(face)
            for k in 0..<3 {
                let a = p[(k + 1) % 3] - p[k], b = p[(k + 2) % 3] - p[k]
                guard length_squared(a) > 0, length_squared(b) > 0 else { continue }
                let angle = acos(min(max(dot(normalize(a), normalize(b)), -1), 1))
                sums[p[k], default: .zero] += normal * angle
            }
        }
        return positions.map { position in
            guard let sum = sums[position], length_squared(sum) > 0 else { return SIMD3(0, 1, 0) }
            return normalize(sum)
        }
    }
}
