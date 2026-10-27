//
//  Flythrough.swift
//  WindageEngine
//

import Foundation
import simd

/// **A fixed camera route through a world, timed the same way every run** (2026-10-27).
///
/// A frame time read off an overlay by someone standing somewhere is not comparable with the next one: two readings from
/// two slightly different places, windowed against full screen, one sample count against another — each mistake looks
/// like a result. **The route is the constant.** The camera flies the same waypoints at the same speed, every frame is
/// recorded against the leg it was drawn on, and the report is per leg as well as for the whole route, so a slow *place*
/// shows up as a slow leg instead of being averaged into one number.
///
/// **The camera follows the ground the whole way**, not only at the waypoints: a straight line between two points on the
/// ground goes through any rise between them, and frames drawn inside a hill see nothing and cost nothing — a route that
/// quietly flatters itself. It looks a little ahead along the path, so it pitches with the ground as a following camera
/// does.
public nonisolated struct Flythrough: Sendable, Equatable {
    /// Where it goes, on the ground: x and z in world metres. The first is where it starts; end where it began for a loop.
    public var waypoints: [SIMD2<Float>]
    /// Metres a second — brisk, not so fast that what loads as it moves is left behind.
    public var speed: Float
    /// Metres above the ground: about where a third-person camera sits, above fences and shrubs.
    public var eyeHeight: Float

    public init(waypoints: [SIMD2<Float>], speed: Float = 18, eyeHeight: Float = 3.5) {
        self.waypoints = waypoints
        self.speed = max(speed, 0.1)
        self.eyeHeight = eyeHeight
    }

    /// **A loop round a piece of ground and across it** — for a world with no route of its own: round the ground a fifth of
    /// the way in from its edges, then corner to corner through the middle. `minimum` and `maximum` are its x and z.
    public static func circuit(minimum: SIMD2<Float>, maximum: SIMD2<Float>, speed: Float = 18,
                               eyeHeight: Float = 3.5) -> Flythrough {
        let inset = (maximum - minimum) * 0.2
        let a = minimum + inset, b = maximum - inset
        return Flythrough(waypoints: [SIMD2(a.x, a.y), SIMD2(b.x, a.y), SIMD2(b.x, b.y), SIMD2(a.x, b.y), SIMD2(a.x, a.y),
                                      SIMD2(b.x, b.y)],
                          speed: speed, eyeHeight: eyeHeight)
    }

    /// How many legs: one fewer than the waypoints.
    public var legs: Int { max(waypoints.count - 1, 0) }

    /// Each leg's length in metres, along the ground's plan.
    public var legLengths: [Float] {
        guard legs > 0 else { return [] }
        return (0..<legs).map { simd_distance(waypoints[$0], waypoints[$0 + 1]) }
    }

    /// The whole route's length in metres.
    public var length: Float { legLengths.reduce(0, +) }

    /// Where the camera is and what it looks at.
    public struct Pose: Sendable, Equatable {
        public var eye: SIMD3<Float>
        public var target: SIMD3<Float>
        /// The leg it is on.
        public var leg: Int
    }

    /// **Where the camera is `distance` metres along**, its height from `ground` (the height under x and z, nil off the
    /// ground — then 0), looking two metres ahead along the path. Past the end, the end.
    public func pose(atDistance distance: Float, ground: (Float, Float) -> Float?) -> Pose {
        let point = place(atDistance: distance)
        let ahead = place(atDistance: distance + 2)
        func lifted(_ p: SIMD2<Float>) -> SIMD3<Float> { SIMD3(p.x, (ground(p.x, p.y) ?? 0) + eyeHeight, p.y) }
        var target = lifted(ahead.at)
        let eye = lifted(point.at)
        if simd_distance_squared(target, eye) < 1e-6 {
            // At the very end there is nothing ahead: keep looking the way the last leg went.
            let last = legs > 0 ? simd_normalize(waypoints[legs] - waypoints[legs - 1] + SIMD2(1e-6, 0)) : SIMD2<Float>(0, -1)
            target = eye + SIMD3(last.x, 0, last.y)
        }
        return Pose(eye: eye, target: target, leg: point.leg)
    }

    private func place(atDistance distance: Float) -> (at: SIMD2<Float>, leg: Int) {
        guard let first = waypoints.first else { return (.zero, 0) }
        var left = max(distance, 0)
        for (leg, length) in legLengths.enumerated() {
            // At a waypoint, on the leg it begins: a frame there is drawn looking along that one.
            if left < length || leg == legs - 1 {
                let t = length > 0 ? min(left / length, 1) : 1
                return (simd_mix(waypoints[leg], waypoints[leg + 1], SIMD2(repeating: t)), leg)
            }
            left -= length
        }
        return (first, 0)
    }
}

/// **A flythrough under way** — the route flown once, or once per pass when costs are being attributed
/// (``FlythroughReport/attribution``). A game ticks it each frame: ``pose(ground:)`` says where to put the camera,
/// ``record(_:seconds:)`` notes what the frame cost and moves it on. Nothing here draws, so it runs in `swift test`.
///
/// **Each pass settles first** — the camera held at the start for a moment — so a pass's first frames are not the cost of
/// whatever the previous pass switched back on.
public nonisolated struct FlythroughRun: Sendable {
    public let route: Flythrough
    /// What each pass is called; one pass, "baseline", unless costs are being attributed. A game switches its pass's thing
    /// off when ``pass`` reaches it, and back on after.
    public let passes: [String]
    /// Seconds held at the start of each pass before timing.
    public var settleSeconds: Float = 0.75
    /// **Drawn into a texture and waited for**, frame by frame, rather than shown (``FrameRenderer/flyThrough(_:passes:width:height:framesPerSecond:ground:place:switchPass:)``):
    /// a frame's interval is then its CPU and GPU time one after the other, not the display's pace, and the report says so.
    public var offScreen = false

    public private(set) var pass = 0
    public private(set) var distance: Float = 0
    public private(set) var settled: Float = 0
    /// Every recorded frame, by pass and then by leg.
    public private(set) var samples: [[[FrameTimes]]]

    /// **The last pass of an attribution run: the baseline flown again** (2026-10-27). Passes flown one after another for
    /// minutes are not flown on the same machine — it warms, and a GPU that has warmed is slower — so the first run of a
    /// suspect measured last read as costing *less* than nothing. Flying the baseline at both ends shows the drift, and
    /// each pass is compared with the baseline as it would have been when that pass flew. Every name but the first and
    /// this one is a suspect; a game switches nothing off for either.
    public static let baselineAgain = "baseline again"

    public init(route: Flythrough, passes: [String] = ["baseline"]) {
        self.route = route
        let named = passes.isEmpty ? ["baseline"] : passes
        self.passes = named.count > 1 ? named + [Self.baselineAgain] : named
        samples = Array(repeating: Array(repeating: [], count: route.legs), count: self.passes.count)
    }

    /// Whether every pass has been flown.
    public var isFinished: Bool { pass >= passes.count || route.legs == 0 }
    /// Whether the camera is still being held at the start of a pass.
    public var isSettling: Bool { !isFinished && settled < settleSeconds }

    /// Where the camera goes for this frame.
    public func pose(ground: (Float, Float) -> Float?) -> Flythrough.Pose {
        route.pose(atDistance: isSettling ? 0 : distance, ground: ground)
    }

    /// **Records the frame just drawn and moves on** by `seconds` — the frame's own time, so the route takes as long as it
    /// takes and every leg is flown at the same speed whatever the frame rate. Returns true when a new pass begins, so the
    /// game can switch the next suspect off.
    @discardableResult
    public mutating func record(_ times: FrameTimes, seconds: Float) -> Bool {
        guard !isFinished else { return false }
        if isSettling {
            settled += seconds
            return false
        }
        let leg = route.pose(atDistance: distance) { _, _ in 0 }.leg
        samples[pass][leg].append(times)
        distance += max(seconds, 0) * route.speed
        // A hair short counts as there: a second of frames at 30 a second adds up to just under a second.
        guard distance >= route.length - 1e-3 else { return false }
        pass += 1
        distance = 0
        settled = 0
        return !isFinished
    }

    /// The report so far.
    public var report: FlythroughReport {
        FlythroughReport(route: route, passes: passes, samples: samples, offScreen: offScreen)
    }
}

/// **What a flythrough measured**: per pass, per leg and for the whole route — the mean as the headline, because with
/// frames queued the median describes the near-empty frames the CPU returns from while the queue has room and only the
/// mean is throughput; the 95th percentile and the worst beside it.
public nonisolated struct FlythroughReport: Sendable {
    public let route: Flythrough
    public let passes: [String]
    public let samples: [[[FrameTimes]]]
    /// Whether the frames were drawn off screen and waited for (``FlythroughRun/offScreen``).
    public let offScreen: Bool

    public init(route: Flythrough, passes: [String], samples: [[[FrameTimes]]], offScreen: Bool = false) {
        self.route = route
        self.passes = passes
        self.samples = samples
        self.offScreen = offScreen
    }

    /// Mean, 95th percentile and worst of some milliseconds.
    public struct Summary: Sendable, Equatable {
        public var frames: Int
        public var mean: Double
        public var p95: Double
        public var worst: Double

        public init(_ values: [Double]) {
            frames = values.count
            guard !values.isEmpty else { mean = 0; p95 = 0; worst = 0; return }
            let sorted = values.sorted()
            mean = values.reduce(0, +) / Double(values.count)
            p95 = sorted[min(max(Int((0.95 * Double(sorted.count - 1)).rounded()), 0), sorted.count - 1)]
            worst = sorted[sorted.count - 1]
        }

        /// Frames a second at the mean.
        public var fps: Double { mean > 0 ? 1000 / mean : 0 }
    }

    /// One pass's frames: every leg's, or one leg's.
    public func frames(pass: Int, leg: Int? = nil) -> [FrameTimes] {
        guard samples.indices.contains(pass) else { return [] }
        if let leg { return samples[pass].indices.contains(leg) ? samples[pass][leg] : [] }
        return samples[pass].flatMap { $0 }
    }

    /// **What a frame cost**: the larger of its CPU and GPU work — what it would take with nothing paced. Its interval
    /// cannot say that on a display that waits for the refresh.
    public static func cost(_ times: FrameTimes) -> Double { max(times.cpu, times.gpu ?? 0) }

    public func interval(pass: Int = 0, leg: Int? = nil) -> Summary { Summary(frames(pass: pass, leg: leg).map(\.interval)) }
    public func cost(pass: Int = 0, leg: Int? = nil) -> Summary { Summary(frames(pass: pass, leg: leg).map(Self.cost)) }
    public func cpu(pass: Int = 0, leg: Int? = nil) -> Summary { Summary(frames(pass: pass, leg: leg).map(\.cpu)) }
    public func gpu(pass: Int = 0, leg: Int? = nil) -> Summary { Summary(frames(pass: pass, leg: leg).compactMap(\.gpu)) }

    /// **The report as text**: what was set (`settings`, a line a game writes — quality, size, sample count), the whole
    /// route, then each leg. With more than one pass, the attribution table instead.
    public func text(title: String, settings: String = "") -> String {
        passes.count > 1 ? attribution(title: title, settings: settings) : single(title: title, settings: settings)
    }

    private func single(title: String, settings: String) -> String {
        var out = "\(title) — flythrough\n"
        if !settings.isEmpty { out += "  \(settings)\n" }
        let whole = cost()
        let metres = Self.f(Double(route.length), 0), pace = Self.f(Double(route.speed), 0)
        out += "  \(route.legs) legs, \(metres) m at \(pace) m/s, \(whole.frames) frames\n"
        guard whole.frames > 0 else { return out + "  no frames.\n" }
        let shown = interval(), work = cpu(), gpuWork = gpu()
        let gpuMean = gpuWork.frames > 0 ? Self.f(gpuWork.mean) : "—"
        out += "  WHOLE ROUTE  cost mean \(Self.f(whole.mean)) ms (\(Self.f(whole.fps, 0)) fps)"
        out += "  p95 \(Self.f(whole.p95))  worst \(Self.f(whole.worst))\n"
        out += "               cpu \(Self.f(work.mean))  gpu \(gpuMean)"
        out += offScreen ? "  each drawn and waited for in \(Self.f(shown.mean)) ms\n\n"
            : "  shown every \(Self.f(shown.mean)) ms (\(Self.f(shown.fps, 0)) fps)\n\n"
        out += "  leg   cost    p95    cpu    gpu  \(offScreen ? "waited" : " shown")   from -> to\n"
        for leg in 0..<route.legs {
            let legCost = cost(leg: leg)
            guard legCost.frames > 0 else { continue }
            let legGPU = gpu(leg: leg)
            let a = route.waypoints[leg], b = route.waypoints[leg + 1]
            let columns: [String] = [
                Self.pad(String(leg), 3),
                Self.pad(Self.f(legCost.mean), 5),
                Self.pad(Self.f(legCost.p95), 5),
                Self.pad(Self.f(cpu(leg: leg).mean), 5),
                Self.pad(legGPU.frames > 0 ? Self.f(legGPU.mean) : "—", 5),
                Self.pad(Self.f(interval(leg: leg).mean), 6),
            ]
            let from = "\(Self.f(Double(a.x), 0)),\(Self.f(Double(a.y), 0))"
            let to = "\(Self.f(Double(b.x), 0)),\(Self.f(Double(b.y), 0))"
            out += "  " + columns.joined(separator: "  ") + "   \(from) -> \(to)\n"
        }
        out += "\n  cost is the larger of the CPU's and the GPU's work for a frame — what it takes with nothing paced.\n"
        out += offScreen ? "  waited is both, one after the other: each frame was drawn off screen and finished before the next.\n"
            : "  shown is how often frames reached the display, which waits for its refresh.\n"
        return out
    }

    /// **What the baseline would have cost while pass `pass` flew** — the first baseline and the last
    /// (``FlythroughRun/baselineAgain``) joined by a straight line through the passes between, so a machine that warmed
    /// as it went does not show up as a cost. The first baseline alone without a second.
    public func baseline(forPass pass: Int, leg: Int? = nil) -> Double {
        let first = cost(pass: 0, leg: leg).mean
        guard passes.count > 2, passes.last == FlythroughRun.baselineAgain else { return first }
        let last = cost(pass: passes.count - 1, leg: leg).mean
        return first + (last - first) * Double(pass) / Double(passes.count - 1)
    }

    /// What switching pass `pass`'s thing off saves, against the baseline of its own time.
    public func saving(pass: Int, leg: Int? = nil) -> Double { baseline(forPass: pass, leg: leg) - cost(pass: pass, leg: leg).mean }

    /// How far the baseline moved between the first pass and the last, in milliseconds — the noise a saving must beat.
    public var drift: Double? {
        guard passes.count > 2, passes.last == FlythroughRun.baselineAgain else { return nil }
        return cost(pass: passes.count - 1).mean - cost(pass: 0).mean
    }

    private func attribution(title: String, settings: String) -> String {
        // Wide enough for the longest pass's name and a gap, so "baseline again" does not run into its neighbour.
        let width = max(13, (passes.map(\.count).max() ?? 0) + 2)
        var out = "\(title) — flythrough, cost attribution\n"
        if !settings.isEmpty { out += "  \(settings)\n" }
        out += "\n  leg  " + passes.map { Self.pad($0, width) }.joined() + "\n"
        for leg in 0..<route.legs {
            out += "  \(Self.pad(String(leg), 3))  "
                + passes.indices.map { Self.pad(Self.f(cost(pass: $0, leg: leg).mean), width) }.joined() + "\n"
        }
        out += "\n  ALL  " + passes.indices.map { Self.pad(Self.f(cost(pass: $0).mean), width) }.joined() + "\n"
        let saves: [String] = passes.indices.map { pass in
            pass == 0 || passes[pass] == FlythroughRun.baselineAgain ? Self.pad("", width) : Self.pad(Self.f(saving(pass: pass)), width)
        }
        out += "  saves" + saves.joined() + "\n"
        if let drift {
            out += "  drift \(Self.f(drift)) ms from the first baseline to the last — each saving is against the baseline of\n"
            out += "  its own time, and a saving smaller than the drift is noise.\n"
        }
        out += "\n"
        out += "  Each column is the whole route flown with that one thing off; its gap from the first is what the thing\n"
        out += "  costs, per leg — so a cost that lives in one corner shows as one expensive leg. Milliseconds of work a frame.\n"
        return out
    }

    static func f(_ value: Double, _ places: Int = 1) -> String { String(format: "%.\(places)f", value) }
    static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
}
