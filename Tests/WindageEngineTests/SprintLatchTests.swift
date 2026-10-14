//
//  SprintLatchTests.swift
//  WindageEngineTests
//

import Testing
@testable import WindageEngine

struct SprintLatchTests {

    private let running: Float = 1.0

    @Test("A click engages sprint and it stays engaged after release")
    func clickLatchesOn() {
        var latch = SprintLatch()
        latch.update(buttonPressed: true, forwardInput: running)
        #expect(latch.isEngaged)

        latch.update(buttonPressed: false, forwardInput: running)
        #expect(latch.isEngaged, "Releasing the button must not stop the sprint")
    }

    @Test("A second click turns it off")
    func secondClickLatchesOff() {
        var latch = SprintLatch()
        latch.update(buttonPressed: true, forwardInput: running)
        latch.update(buttonPressed: false, forwardInput: running)
        latch.update(buttonPressed: true, forwardInput: running)
        #expect(!latch.isEngaged)
    }

    /// The bug that level-triggering instead of edge-triggering produces: a button held for a
    /// second toggles sixty times, so whether you end up sprinting is effectively a coin flip.
    @Test("Holding the button toggles once, not once per frame")
    func holdingTogglesOnce() {
        var latch = SprintLatch()
        for _ in 0..<60 { latch.update(buttonPressed: true, forwardInput: running) }
        #expect(latch.isEngaged)
    }

    @Test("Stopping expires the latch")
    func stoppingDisengages() {
        var latch = SprintLatch()
        latch.update(buttonPressed: true, forwardInput: running)
        #expect(latch.isEngaged)

        latch.update(buttonPressed: false, forwardInput: 0)
        #expect(!latch.isEngaged)
    }

    /// After stopping clears it, moving off again must be a walk — the player never asked to
    /// sprint again.
    @Test("Sprint does not resume by itself after a stop")
    func doesNotResumeAfterStopping() {
        var latch = SprintLatch()
        latch.update(buttonPressed: true, forwardInput: running)
        latch.update(buttonPressed: false, forwardInput: 0)
        latch.update(buttonPressed: false, forwardInput: running)
        #expect(!latch.isEngaged)
    }

    @Test("Walking backwards does not count as sprinting forward")
    func reversingDisengages() {
        var latch = SprintLatch()
        latch.update(buttonPressed: true, forwardInput: running)
        latch.update(buttonPressed: false, forwardInput: -1)
        #expect(!latch.isEngaged)
    }

    @Test("Losing focus clears it")
    func disengageResets() {
        var latch = SprintLatch()
        latch.update(buttonPressed: true, forwardInput: running)
        latch.disengage()
        #expect(!latch.isEngaged)

        // And the next press must still register as a fresh edge.
        latch.update(buttonPressed: true, forwardInput: running)
        #expect(latch.isEngaged)
    }
}
