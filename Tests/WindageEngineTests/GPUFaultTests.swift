//
//  GPUFaultTests.swift
//  WindageEngineTests
//

import Testing
import Foundation
import Metal
@testable import WindageEngine

/// **A failed frame read from Metal 4's error** (2026-10-29): the page fault, or the access revoked after faults, is in
/// the errors under a generic one — and a revoked process must be told apart, since no frame will ever signal again.
struct GPUFaultTests {

    private func metal4(_ code: Int, _ message: String? = nil, under: [NSError] = []) -> NSError {
        var info: [String: Any] = [:]
        if let message { info[NSLocalizedDescriptionKey] = message }
        if under.count == 1 { info[NSUnderlyingErrorKey] = under[0] }
        if under.count > 1 { info[NSMultipleUnderlyingErrorsKey] = under }
        return NSError(domain: MTL4CommandQueueErrorDomain, code: code, userInfo: info)
    }

    @Test func aPageFaultIsNamedAndNotRevoked() {
        let fault = FrameGPUClock.fault(frame: 5, error: metal4(1, under: [
            metal4(2, "Caused GPU Address Fault Error (0000000b:kIOGPUCommandBufferCallbackErrorPageFault)")]))
        #expect(fault.frame == 5)
        #expect(fault.description.contains("Address Fault"))
        #expect(!fault.revoked)
    }

    @Test func accessRevokedIsFoundAmongSeveralUnderlyingErrors() {
        let fault = FrameGPUClock.fault(frame: 9, error: metal4(1, under: [
            NSError(domain: "IOGPUCommandQueueErrorDomain", code: 4),
            metal4(MTL4CommandQueueError.accessRevoked.rawValue, "Ignored (for causing prior/excessive GPU errors)")]))
        #expect(fault.revoked)
        #expect(fault.description.hasPrefix("Ignored"))
    }

    @Test func theClockKeepsTheFirstFaultAsTheCause() {
        let clock = FrameGPUClock()
        clock.record(frame: 5, error: metal4(1, under: [metal4(2, "page fault")]))
        clock.record(frame: 8, error: metal4(1, under: [metal4(MTL4CommandQueueError.accessRevoked.rawValue, "ignored")]))
        #expect(clock.first?.frame == 5)
        #expect(clock.fault(forFrame: 8)?.revoked == true)
        #expect(clock.fault(forFrame: 6) == nil)
    }
}
