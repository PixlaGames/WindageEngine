//
//  FrameClock.swift
//  WindageEngine
//

import Foundation

/// How much time each frame — or, with the window hidden, each tick of a timer — hands the
/// simulation. The arithmetic behind ``FrameRenderer/runsWhileHidden``, apart from the display link and
/// the timer so it can be tested.
///
/// **Two clocks, and the difference is the whole difficulty.** A display-link frame is stamped with
/// when it will be *shown* — some 50 ms ahead of the host clock — and frames credit the time between
/// those stamps. A timer knows only the host clock. Crediting the timer up to *now* and letting the
/// next frame count from its stamp counts that lead twice: measured, one 40 ms jump on every return of
/// the window. So the timer moves the frames' clock on by exactly what it credits.
nonisolated struct FrameClock {

    /// How long frames may stop before the timer takes over — three frames at the display link's
    /// slowest rate, so an ordinary long frame is not mistaken for a hidden window.
    static let quietAfter: Double = 0.1

    /// The last frame's presentation stamp, moved on by whatever the timer has credited since.
    private(set) var lastPresentation: Double?
    /// When the last frame arrived, on the host clock.
    private(set) var lastFrameAt: Double?
    /// How far time has been credited, on the host clock.
    private(set) var creditedAt: Double?

    /// A frame, to be shown at `presented`, arriving at host time `now`. Returns the time it credits —
    /// none for the first, which has nothing before it.
    mutating func frame(presented: Double, now: Double) -> Double {
        // The first frame after a start with none — a window opened hidden and shown later — counts
        // the host clock since the timer last credited, not a stamp that has no predecessor.
        let credit = lastPresentation.map { presented - $0 } ?? creditedAt.map { now - $0 } ?? 0
        lastPresentation = presented
        lastFrameAt = now
        creditedAt = now
        return credit
    }

    /// A timer tick at host time `now`. Returns the time it credits — nil while frames are arriving,
    /// and on the very first tick, which only starts the clock when no frame has come.
    mutating func tick(now: Double) -> Double? {
        // **No frame yet: a window that opened hidden**, and may never be shown — a check run in the
        // background, a game launched behind a full-screen one. Waiting for a first frame, it waited
        // for ever. Time starts at the first tick instead.
        guard let lastFrameAt else {
            guard let creditedAt else { creditedAt = now; return nil }
            self.creditedAt = now
            return now - creditedAt
        }
        guard now - lastFrameAt > FrameClock.quietAfter,
              let creditedAt, let lastPresentation else { return nil }
        let elapsed = now - creditedAt
        self.creditedAt = now
        self.lastPresentation = lastPresentation + elapsed
        return elapsed
    }
}
