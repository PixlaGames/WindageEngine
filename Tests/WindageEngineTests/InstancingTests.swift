//
//  InstancingTests.swift
//  WindageEngineTests
//

import Testing
import simd
@testable import WindageEngine

@MainActor
struct InstancingTests {

    private func move(_ x: Float) -> simd_float4x4 { simd_float4x4(translation: SIMD3(x, 0, 0)) }

    @Test func copiesOfAKindAreGroupedTogether() {
        let batches = InstanceBatches([("pine", move(1)), ("rock", move(2)), ("pine", move(3)), ("rock", move(4))])
        #expect(batches.batches.map(\.key) == ["pine", "rock"])
        #expect(batches.batches.map(\.count) == [2, 2])
        #expect(batches.transforms.map { $0.columns.3.x } == [1, 3, 2, 4])
    }

    @Test func eachBatchPointsAtItsOwnTransforms() {
        let batches = InstanceBatches([("a", move(1)), ("b", move(2)), ("b", move(3)), ("c", move(4)), ("a", move(5))])
        for batch in batches.batches {
            let run = batches.transforms[batch.start..<(batch.start + batch.count)]
            let xs = run.map { $0.columns.3.x }
            switch batch.key {
            case "a": #expect(xs == [1, 5])
            case "b": #expect(xs == [2, 3])
            default: #expect(xs == [4])
            }
            #expect(batch.byteOffset == batch.start * 64, "a float4x4 is 64 bytes")
        }
    }

    @Test func kindsComeInTheOrderFirstSeenEveryTime() {
        // Many keys, so a dictionary's order would almost certainly differ from this.
        let keys = (0..<50).map { "kind\($0)" }
        let copies = keys.reversed().map { ($0, move(0)) } + keys.map { ($0, move(1)) }
        let first = InstanceBatches(copies).batches.map(\.key)
        #expect(first == Array(keys.reversed()))
        for _ in 0..<5 { #expect(InstanceBatches(copies).batches.map(\.key) == first) }
    }

    @Test func nothingGivenIsEmpty() {
        let batches = InstanceBatches<String>([])
        #expect(batches.isEmpty && batches.batches.isEmpty)
    }

    @Test func theBufferGrowsWithRoomToSpareAndNeverShrinks() {
        #expect(InstanceBuffer.capacity(for: 10, current: 0) == InstanceBuffer.minimumCapacity)
        #expect(InstanceBuffer.capacity(for: 900, current: 1024) == 1024, "fits: unchanged")
        #expect(InstanceBuffer.capacity(for: 2000, current: 1024) == 3000, "half as much again")
        #expect(InstanceBuffer.capacity(for: 10, current: 3000) == 3000, "never shrinks")
    }
}
