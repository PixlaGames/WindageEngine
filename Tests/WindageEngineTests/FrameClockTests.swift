//
//  FrameClockTests.swift
//  WindageEngineTests
//

import Testing
@testable import WindageEngine

/// The time a hidden window's simulation is handed: by frames while they arrive, by a timer while they
/// do not, and never the same stretch twice. Every case has the display link's lead — its frames are
/// stamped 48 ms ahead of the host clock, as measured — because a clock that is right only with no lead
/// is right only in a test.
@Suite("Frame clock — frames, and a timer while there are none")
struct FrameClockTests {

    private let lead = 0.048, frame = 1.0 / 60, tick = 1.0 / 60

    /// Frames at 60 a second from host time `from`, for `seconds`. Returns the time they credited.
    private func frames(_ clock: inout FrameClock, from: Double, seconds: Double) -> Double {
        var credited = 0.0, t = from
        while t < from + seconds - 1e-9 {
            credited += clock.frame(presented: t + lead, now: t)
            // The timer is still running while frames arrive; it must hand over nothing.
            #expect(clock.tick(now: t + tick / 2) == nil, "the timer credited time while frames were arriving")
            t += frame
        }
        return credited
    }

    private func ticks(_ clock: inout FrameClock, from: Double, seconds: Double) -> Double {
        var credited = 0.0, t = from
        while t < from + seconds - 1e-9 {
            credited += clock.tick(now: t) ?? 0
            t += tick
        }
        return credited
    }

    @Test("Frames alone credit the time between their stamps")
    func framesAlone() {
        var clock = FrameClock()
        // Sixty frames: fifty-nine gaps between them, the first frame crediting nothing.
        let credited = frames(&clock, from: 100, seconds: 1)
        #expect(abs(credited - 59 * frame) < 1e-9, "credited \(credited)")
    }

    @Test("With frames stopped, the timer credits the wall clock — the silence before it took over included")
    func hiddenKeepsTime() {
        var clock = FrameClock()
        _ = frames(&clock, from: 100, seconds: 1)
        let lastFrame = 100 + 59 * frame
        // Nothing for 0.1 s — an ordinary long frame, not a hidden window — and then ten seconds of ticks.
        #expect(clock.tick(now: lastFrame + 0.05) == nil, "took over during an ordinary long frame")
        let credited = ticks(&clock, from: lastFrame + 0.15, seconds: 10)
        let lastTick = lastFrame + 0.15 + (10 / tick - 1).rounded() * tick
        #expect(abs(credited - (lastTick - lastFrame)) < 1e-6, "credited \(credited) s of \(lastTick - lastFrame) s")
    }

    /// **The point of the second clock.** Counting the first frame back from the last tick's host
    /// time, not from the stamps' clock moved on, credits the frames' 48 ms lead a second time.
    @Test("The first frame back credits one frame, not the display link's lead again")
    func returningFrame() {
        var clock = FrameClock()
        _ = frames(&clock, from: 100, seconds: 1)
        _ = ticks(&clock, from: 101, seconds: 5)
        let lastTick = 101 + (5 / tick - 1).rounded() * tick
        let back = lastTick + frame
        let credited = clock.frame(presented: back + lead, now: back)
        #expect(abs(credited - frame) < 1e-6, "the first frame back credited \(credited) s, one frame is \(frame)")
    }

    @Test("Over hiding and showing, what is credited is what went by")
    func wholeCycle() {
        var clock = FrameClock()
        var credited = frames(&clock, from: 100, seconds: 2)
        credited += ticks(&clock, from: 100 + 2 * frame * 60 - frame + 0.2, seconds: 7)
        let resume = 110.0
        credited += frames(&clock, from: resume, seconds: 3)
        let wentBy = (resume + 3 - frame) - 100
        #expect(abs(credited - wentBy) < 1e-6, "credited \(credited) s of \(wentBy) s")
    }

    /// A window opened hidden gets no frame. The timer's first tick starts the clock, and it keeps the
    /// wall clock from there — where it used to wait for a first frame that never came.
    @Test("With no frame ever, the timer keeps time from its first tick")
    func startedHidden() {
        var clock = FrameClock()
        #expect(clock.tick(now: 50) == nil, "the first tick only starts the clock")
        let credited = ticks(&clock, from: 50 + tick, seconds: 10)
        let lastTick = 50 + tick + (10 / tick - 1).rounded() * tick
        #expect(abs(credited - (lastTick - 50)) < 1e-6, "credited \(credited) s of \(lastTick - 50) s")
        // Shown at last: the first frame counts from the last tick on the host clock, not its stamp's lead.
        let shown = lastTick + frame
        #expect(abs(clock.frame(presented: shown + lead, now: shown) - frame) < 1e-6)
        #expect(abs(clock.frame(presented: shown + frame + lead, now: shown + frame) - frame) < 1e-6)
    }
}
