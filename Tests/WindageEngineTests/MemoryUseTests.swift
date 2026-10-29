//
//  MemoryUseTests.swift
//  WindageEngineTests
//

import Testing
import Foundation
import Metal
@testable import WindageEngine

/// A statistics readout's numbers: memory measured from inside the process, and frame times averaged for reading.
struct MemoryUseTests {

    @Test func footprintIsReadAndGrowsWithWhatIsTouched() throws {
        let before = try #require(MemoryUse.footprint())
        #expect(before > 1 << 20, "a running test process holds more than a megabyte")
        // Sixty-four megabytes written to, so dirtied: the footprint counts them.
        let size = 64 << 20
        let block = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16_384)
        defer { block.deallocate() }
        memset(block, 1, size)
        let after = try #require(MemoryUse.footprint())
        #expect(after - before > size / 2)
    }

    @Test func graphicsCountsWhatTheDeviceAllocated() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let before = MemoryUse.measure(device: device)
        let buffer = try #require(device.makeBuffer(length: 32 << 20, options: .storageModeShared))
        let after = MemoryUse.measure(device: device)
        #expect(after.graphics - before.graphics >= buffer.allocatedSize)
        #expect(after.graphicsBudget > 0)
        #expect(after.graphicsShare > 0 && after.graphicsShare < 1)
        _ = buffer
    }

    @Test func allocationsSharedAreCountedOnce() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }
        let buffer = try #require(device.makeBuffer(length: 1 << 20, options: .storageModeShared))
        let other = try #require(device.makeBuffer(length: 1 << 20, options: .storageModeShared))
        #expect(MemoryUse.bytes(of: [buffer, other, buffer]) == buffer.allocatedSize + other.allocatedSize)
        #expect(MemoryUse.bytes(of: []) == 0)
    }

    @Test func noBudgetIsNoShare() {
        #expect(MemoryUse(footprint: 1, graphics: 10, graphicsBudget: 0).graphicsShare == 0)
        #expect(MemoryUse(footprint: 1, graphics: 25, graphicsBudget: 100).graphicsShare == 0.25)
    }

    @Test func averageOfFrames() throws {
        var average = FrameTimesAverage()
        #expect(average.mean == nil)
        // The first frame has nothing before it: its interval of 0 is not a frame to average.
        average.add(FrameTimes(interval: 0, cpu: 1, gpu: nil))
        #expect(average.frames == 0)
        average.add(FrameTimes(interval: 10, cpu: 2, gpu: nil))
        average.add(FrameTimes(interval: 20, cpu: 4, gpu: 6))
        let mean = try #require(average.mean)
        #expect(mean.interval == 15)
        #expect(mean.cpu == 3)
        // Only the frames that reported a GPU time are in its average.
        #expect(mean.gpu == 6)
        #expect(average.slowest == 20)
        average.reset()
        #expect(average.mean == nil && average.slowest == 0)
    }
}
