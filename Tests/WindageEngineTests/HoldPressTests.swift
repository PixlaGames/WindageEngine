//
//  HoldPressTests.swift
//  WindageEngineTests
//

import Testing
@testable import WindageEngine

struct HoldPressTests {

    private func hold(_ press: inout HoldPress, for seconds: Float, isHeld: Bool = true, step: Float = 1 / 60) -> Int {
        var acted = 0
        for _ in 0..<Int((seconds / step).rounded()) where press.step(isHeld: isHeld, deltaTime: step) { acted += 1 }
        return acted
    }

    @Test("Held past its duration it acts once, while still held")
    func actsOnce() {
        var press = HoldPress(duration: 0.3)
        #expect(hold(&press, for: 0.25) == 0)
        #expect(press.progress > 0.8 && press.progress < 1)
        #expect(hold(&press, for: 0.1) == 1, "it acts on reaching the duration, not on letting go")
        #expect(hold(&press, for: 2) == 0, "held on, it does not act again")
        #expect(press.progress == 0)
    }

    @Test("Let go early, nothing; it has to come up before it can act again")
    func tapsDoNothing() {
        var press = HoldPress(duration: 0.3)
        #expect(hold(&press, for: 0.2) == 0)
        #expect(hold(&press, for: 0.1, isHeld: false) == 0)
        #expect(hold(&press, for: 0.2) == 0, "a fresh hold starts from nothing")
        #expect(hold(&press, for: 0.15) == 1)
        _ = hold(&press, for: 0.05, isHeld: false)
        #expect(hold(&press, for: 0.35) == 1, "released and held again, it acts again")
    }

    @Test("The same moment at any step length")
    func anyRate() {
        var fast = HoldPress(duration: 0.3), slow = HoldPress(duration: 0.3)
        var fastAt: Float = 0, slowAt: Float = 0
        while !fast.step(isHeld: true, deltaTime: 1 / 120) { fastAt += 1 / 120 }
        while !slow.step(isHeld: true, deltaTime: 1 / 20) { slowAt += 1 / 20 }
        #expect(abs(fastAt - slowAt) <= 1 / 20 + 1e-4)
    }

    @Test("Cancelled under the thumb, it does not act until the button comes up and goes down again")
    func cancel() {
        var press = HoldPress(duration: 0.3)
        _ = hold(&press, for: 0.2)
        press.cancel()
        #expect(hold(&press, for: 1) == 0)
        _ = hold(&press, for: 0.05, isHeld: false)
        #expect(hold(&press, for: 0.35) == 1)
        var up = HoldPress(duration: 0.3)
        up.cancel()
        #expect(hold(&up, for: 0.35) == 1, "cancelled while up, the next hold acts as usual")
    }
}
