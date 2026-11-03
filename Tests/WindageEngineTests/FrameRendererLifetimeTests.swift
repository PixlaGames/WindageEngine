import Foundation
import Testing
import Metal
@testable import WindageEngine

@Suite("Frame renderer lifetime")
struct FrameRendererLifetimeTests {
    /// **A `CAMetalLayer` keeps the command queue that last presented to it**, and a queue keeps every residency set added
    /// to it — so a renderer freed while its layer lived on kept everything it had made resident. Here the test keeps the
    /// queue, as the layer would.
    @Test("A freed renderer lets go of what it made resident, though its queue lives on")
    @MainActor
    func freedRendererReleasesItsAllocations() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        var renderer: FrameRenderer? = try FrameRenderer(device: device)
        let queue = try #require(renderer?.commandQueue)
        weak var buffer: (any MTLBuffer)?
        do {
            let made = try #require(device.makeBuffer(length: 4096, options: .storageModeShared))
            renderer?.residencySet.addAllocation(made)
            renderer?.commitResidency()
            buffer = made
        }
        #expect(buffer != nil)
        renderer = nil
        #expect(buffer == nil)
        withExtendedLifetime(queue) {}
    }
}
