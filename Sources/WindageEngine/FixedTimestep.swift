//
//  FixedTimestep.swift
//  WindageEngine
//

import Foundation

/// Advances simulation in fixed increments, independently of how often — or how irregularly —
/// frames arrive.
///
/// **Why this exists, rather than simulating with each frame's own delta.** A bullet in a shooter is
/// in flight for seconds, under gravity and drag, and each step's result feeds the next. Integrate
/// that with a variable delta and the same shot lands somewhere different on a 60 Hz display than
/// on a 120 Hz one, and somewhere different again on a frame that happened to stutter. A shot that
/// misses because the machine was busy is not a game.
///
/// So wall-clock time accumulates here and is spent in identical increments of ``stepDuration``.
/// Rendering still happens as often as the display allows; it just draws the simulation *between*
/// steps, using ``interpolation``.
///
/// **Seconds as `Double` here, and `Float` in `GameLoop.step(deltaTime:)`.** This is a clock: it adds
/// frame times up for as long as the game runs, and a `Float` running sum loses precision as it
/// grows — after an hour its smallest step is a quarter of a millisecond. What a step hands the
/// simulation is one short span, where `Float` is what every system it reaches — the camera,
/// particles, a character — already works in.
///
/// **`nonisolated` on purpose.** The target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so
/// everything here is main-actor-bound unless it says otherwise. The simulation clock is precisely
/// the thing that must be free of that: it is pure value-type arithmetic today, and it moves to the
/// render thread the moment frames stop being driven from the main run loop.
public nonisolated struct FixedTimestep: Sendable {

    /// Duration of one simulation step, in seconds.
    public let stepDuration: Double

    /// Longest single frame that will be honored, in seconds.
    ///
    /// Without this a long stall — a breakpoint, a window drag, a texture upload — hands over a
    /// huge delta, which becomes a burst of steps, which takes longer than a frame, which makes the
    /// next delta larger still. Time is deliberately *lost* instead: the simulation runs slow for
    /// an instant rather than spiralling.
    public let maxFrameTime: Double

    /// Unspent time carried into the next frame, in seconds; always less than ``stepDuration``.
    public private(set) var accumulator: Double = 0

    /// Total simulated time, in seconds, which advances only in whole steps and so is exactly
    /// reproducible.
    public private(set) var simulatedTime: Double = 0

    /// Total steps taken since the clock started.
    public private(set) var totalSteps: Int = 0

    public init(stepsPerSecond: Double, maxFrameTime: Double = 0.25) {
        precondition(stepsPerSecond > 0, "A simulation rate must be positive")
        precondition(maxFrameTime > 0, "A frame-time ceiling must be positive")
        self.stepDuration = 1.0 / stepsPerSecond
        self.maxFrameTime = maxFrameTime
    }

    /// Adds one frame's elapsed wall-clock time and reports how many fixed steps are now due.
    ///
    /// Negative deltas are treated as zero: the clock never runs backwards, whatever the timestamps
    /// say.
    @discardableResult
    public mutating func advance(by frameTime: Double) -> Int {
        accumulator += min(max(frameTime, 0), maxFrameTime)

        let steps = Int(accumulator / stepDuration)
        if steps > 0 {
            accumulator -= Double(steps) * stepDuration
            simulatedTime += Double(steps) * stepDuration
            totalSteps += steps
        }
        return steps
    }

    /// How far the display currently sits between the last completed step and the next, in `0..<1`.
    ///
    /// Render interpolated state by this much and motion stays smooth even though the simulation
    /// moves in discrete jumps. Without it, a 120 Hz display showing a 60 Hz simulation shows every
    /// position twice, which reads as judder.
    ///
    /// The value ``GameLoop`` hands every `encode` call as `interpolation`.
    public var interpolation: Float { Float(accumulator / stepDuration) }
}
