//
//  TransformHierarchyTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

@Suite("Transform hierarchy")
struct TransformHierarchyTests {

    private func translation(_ x: Float, _ y: Float, _ z: Float) -> matrix_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(x, y, z, 1)
        return m
    }

    private func scale(_ s: Float) -> matrix_float4x4 {
        matrix_float4x4(diagonal: SIMD4(s, s, s, 1))
    }

    /// A quarter turn about +Y, so a child offset along +X ends up along −Z.
    private var quarterTurn: matrix_float4x4 {
        matrix_float4x4(columns: (SIMD4( 0, 0, -1, 0),
                                  SIMD4( 0, 1,  0, 0),
                                  SIMD4( 1, 0,  0, 0),
                                  SIMD4( 0, 0,  0, 1)))
    }

    private func position(_ m: matrix_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    @Test("a child is placed by its parent")
    func childFollowsParent() throws {
        var hierarchy = try TransformHierarchy(
            attachments: [.world, .node(0)],
            localTransforms: [translation(10, 0, 0), translation(0, 2, 0)])
        hierarchy.refresh()
        #expect(position(hierarchy.worldTransform(of: 0)) == SIMD3(10, 0, 0))
        #expect(position(hierarchy.worldTransform(of: 1)) == SIMD3(10, 2, 0))
    }

    @Test("a parent's rotation turns the child's offset with it")
    func rotationCarries() throws {
        var hierarchy = try TransformHierarchy(
            attachments: [.world, .node(0)],
            localTransforms: [quarterTurn, translation(3, 0, 0)])
        hierarchy.refresh()
        let child = position(hierarchy.worldTransform(of: 1))
        #expect(abs(child.x) < 1e-6)
        #expect(abs(child.z + 3) < 1e-6)
    }

    /// **One forward pass, which is what parent-first ordering buys.** A grandchild has to be right
    /// after a single `refresh`, not after two.
    @Test("a chain resolves in one pass")
    func chainResolvesInOnePass() throws {
        var hierarchy = try TransformHierarchy(
            attachments: [.world, .node(0), .node(1), .node(2)],
            localTransforms: [translation(1, 0, 0), translation(1, 0, 0),
                              translation(1, 0, 0), translation(1, 0, 0)])
        hierarchy.refresh()
        #expect(position(hierarchy.worldTransform(of: 3)) == SIMD3(4, 0, 0))
    }

    @Test("an external parent places a node the hierarchy does not own")
    func externalParent() throws {
        var hierarchy = try TransformHierarchy(
            attachments: [.external(1)],
            localTransforms: [translation(0, 0.5, 0)],   // the grip, authored once
            externalCount: 2)
        hierarchy.refresh(attachedTo: [matrix_identity_float4x4, translation(-4, 1, 7)])
        #expect(position(hierarchy.worldTransform(of: 0)) == SIMD3(-4, 1.5, 7))

        // The grip is untouched by the move — which is the whole reason it is a separate array.
        hierarchy.refresh(attachedTo: [matrix_identity_float4x4, translation(9, 0, 0)])
        #expect(position(hierarchy.worldTransform(of: 0)) == SIMD3(9, 0.5, 0))
        #expect(position(hierarchy.localTransforms[0]) == SIMD3(0, 0.5, 0))
    }

    @Test("a node hangs off a node that hangs off an external one")
    func externalThenLocal() throws {
        var hierarchy = try TransformHierarchy(
            attachments: [.external(0), .node(0)],
            localTransforms: [translation(0, 1, 0), translation(0, 0, 2)],
            externalCount: 1)
        hierarchy.refresh(attachedTo: [quarterTurn])
        // The external turn applies to both offsets: (0,1,0) is on the axis, (0,0,2) rotates to (2,0,0).
        let leaf = position(hierarchy.worldTransform(of: 1))
        #expect(abs(leaf.x - 2) < 1e-6)
        #expect(abs(leaf.y - 1) < 1e-6)
        #expect(abs(leaf.z) < 1e-6)
    }

    // MARK: - The faults, none of which can be seen by looking

    @Test("a parent resolved after its child is refused")
    func parentAfterChildIsRefused() {
        #expect(throws: TransformHierarchyError.self) {
            _ = try TransformHierarchy(attachments: [.node(1), .world])
        }
    }

    @Test("a node attached to itself is refused")
    func selfParentIsRefused() {
        #expect(throws: TransformHierarchyError.self) {
            _ = try TransformHierarchy(attachments: [.world, .node(1)])
        }
    }

    @Test("a parent that is not in the hierarchy is refused")
    func unknownParentIsRefused() {
        #expect(throws: TransformHierarchyError.self) {
            _ = try TransformHierarchy(attachments: [.world, .node(7)])
        }
    }

    /// The one that would otherwise be a silent identity at sixty hertz.
    @Test("an external index past what was declared is refused")
    func unknownExternalIsRefused() {
        #expect(throws: TransformHierarchyError.self) {
            _ = try TransformHierarchy(attachments: [.external(2)], externalCount: 2)
        }
        #expect(throws: Never.self) {
            _ = try TransformHierarchy(attachments: [.external(1)], externalCount: 2)
        }
    }

    @Test("a transform for every node, or none at all")
    func countsMustMatch() {
        #expect(throws: TransformHierarchyError.self) {
            _ = try TransformHierarchy(attachments: [.world, .world],
                                       localTransforms: [matrix_identity_float4x4])
        }
        #expect(throws: Never.self) {
            _ = try TransformHierarchy(attachments: [.world, .world])
        }
    }

    /// **The MUST this replaced:** `localTransforms` was a settable array, so one short was accepted
    /// and read past its end by the next refresh.
    @Test("local transforms are replaced whole only at the right count, and one at a time by index")
    func localTransformsAreChecked() throws {
        var hierarchy = try TransformHierarchy(attachments: [.world, .node(0)])
        #expect(throws: TransformHierarchyError.countMismatch(attachments: 2, transforms: 1)) {
            try hierarchy.setLocalTransforms([translation(1, 0, 0)])
        }
        #expect(hierarchy.localTransforms == [matrix_identity_float4x4, matrix_identity_float4x4],
                "a refused replacement changed nothing")
        try hierarchy.setLocalTransforms([translation(1, 0, 0), translation(0, 2, 0)])
        hierarchy.setLocalTransform(translation(0, 3, 0), ofNode: 1)
        hierarchy.refresh()
        #expect(position(hierarchy.worldTransform(of: 1)) == SIMD3(1, 3, 0))
    }

    // MARK: - Scale, which is the trap

    @Test("scale comes out, rotation and position stay")
    func scaleIsRemoved() {
        let m = translation(5, 6, 7) * quarterTurn * scale(0.01)
        let rigid = m.withoutScale
        #expect(position(rigid) == SIMD3(5, 6, 7))
        for column in [rigid.columns.0, rigid.columns.1, rigid.columns.2] {
            #expect(abs(simd_length(SIMD3(column.x, column.y, column.z)) - 1) < 1e-6)
        }
        // The rotation survives: +X still maps to −Z.
        let turned = rigid * SIMD4<Float>(1, 0, 0, 0)
        #expect(abs(turned.z + 1) < 1e-6)
    }

    /// **The case this exists for.** A rig in centimetres hands its wrist a hundredfold scale; a
    /// held object inheriting it is drawn at one percent of its size, in the right place.
    @Test("a held object keeps its size when the scale is taken out")
    func heldObjectKeepsItsSize() throws {
        let hand = translation(0.4, 1.5, 0) * scale(0.01)
        var inheriting = try TransformHierarchy(attachments: [.external(0)],
                                                localTransforms: [translation(0, -0.2, 0)],
                                                externalCount: 1)
        inheriting.refresh(attachedTo: [hand])
        // A 20 cm drop became 2 mm, and the size of whatever hangs here shrank by the same hundred.
        #expect(abs(position(inheriting.worldTransform(of: 0)).y - 1.498) < 1e-5)
        #expect(abs(simd_length(SIMD3(inheriting.worldTransform(of: 0).columns.0.x,
                                      inheriting.worldTransform(of: 0).columns.0.y,
                                      inheriting.worldTransform(of: 0).columns.0.z)) - 0.01) < 1e-6)

        var rigid = inheriting
        rigid.refresh(attachedTo: [hand.withoutScale])
        #expect(abs(position(rigid.worldTransform(of: 0)).y - 1.3) < 1e-5)
        #expect(abs(simd_length(SIMD3(rigid.worldTransform(of: 0).columns.0.x,
                                      rigid.worldTransform(of: 0).columns.0.y,
                                      rigid.worldTransform(of: 0).columns.0.z)) - 1) < 1e-6)
    }

    @Test("a degenerate axis is left alone rather than turned into NaN")
    func zeroAxisSurvives() {
        var flat = matrix_identity_float4x4
        flat.columns.1 = SIMD4(0, 0, 0, 0)
        let rigid = flat.withoutScale
        #expect(rigid.columns.1 == SIMD4<Float>(0, 0, 0, 0))
        #expect(!rigid.columns.0.x.isNaN)
    }
}

@Test func aLocalTransformForANodeThatIsNotThereIsRefused() async {
    await #expect(processExitsWith: .failure) {
        var hierarchy = try TransformHierarchy(attachments: [.world])
        hierarchy.setLocalTransform(matrix_identity_float4x4, ofNode: 1)
    }
}
