import Foundation
import Metal
import simd
import Testing
@testable import WindageEngine

/// A fixed route, flown and timed the same way every run.
@Suite("Flythrough")
struct FlythroughTests {
    /// A ridge 10 m high across x = 50, flat elsewhere.
    static func ridge(_ x: Float, _ z: Float) -> Float? { max(0, 10 - abs(x - 50)) }

    let line = Flythrough(waypoints: [SIMD2(0, 0), SIMD2(100, 0), SIMD2(100, 50)], speed: 10, eyeHeight: 2)

    @Test("Legs and length along the ground's plan")
    func length() {
        #expect(line.legs == 2 && line.legLengths == [100, 50] && line.length == 150)
        let loop = Flythrough.circuit(minimum: SIMD2(-100, -100), maximum: SIMD2(100, 100))
        #expect(loop.waypoints.first == SIMD2(-60, -60) && loop.waypoints.allSatisfy { abs($0.x) == 60 && abs($0.y) == 60 })
    }

    @Test("The camera follows the ground between waypoints, not a straight line through a rise, and looks ahead")
    func followsTheGround() {
        let top = line.pose(atDistance: 50, ground: Self.ridge)
        #expect(top.eye == SIMD3(50, 12, 0), "over the ridge, not through it")
        #expect(top.target.x > top.eye.x && top.leg == 0)
        let second = line.pose(atDistance: 125, ground: Self.ridge)
        #expect(second.leg == 1 && second.eye == SIMD3(100, 2, 25))
        let end = line.pose(atDistance: 1_000, ground: Self.ridge)
        #expect(end.eye == SIMD3(100, 2, 50) && end.target.z > end.eye.z, "past the end, the end, still looking along")
    }

    @Test("A run settles, records each frame against its leg, and takes as long as the route at its speed")
    func run() {
        var run = FlythroughRun(route: line)
        run.settleSeconds = 0.5
        let frame = FrameTimes(interval: 16.7, cpu: 4, gpu: 6)
        var frames = 0
        while !run.isFinished && frames < 10_000 {
            run.record(frame, seconds: 0.1)
            frames += 1
        }
        #expect(run.isFinished)
        #expect(frames == 5 + 150, "five frames held, then 15 s of route at a tenth of a second each")
        #expect(run.samples[0][0].count == 100 && run.samples[0][1].count == 50)
    }

    @Test("Each pass flies the whole route again, and says when it begins")
    func passes() {
        var run = FlythroughRun(route: line, passes: ["baseline", "no shadows"])
        run.settleSeconds = 0
        var began: [Int] = []
        while !run.isFinished {
            let cpu: Double = run.passes[run.pass] == "no shadows" ? 5 : 8
            if run.record(FrameTimes(interval: 10, cpu: cpu), seconds: 1) { began.append(run.pass) }
        }
        #expect(run.passes == ["baseline", "no shadows", FlythroughRun.baselineAgain], "the baseline flown again at the end")
        #expect(began == [1, 2])
        let report = run.report
        #expect(report.cost(pass: 0).mean == 8 && report.cost(pass: 1).mean == 5 && report.drift == 0)
        let text = report.text(title: "Test")
        #expect(text.contains("cost attribution") && text.contains("no shadows") && text.contains("saves"))
        #expect(text.contains("3.0"), "no shadows saves 3 ms")
    }

    @Test("A machine that warms as it goes is not read as a cost: each pass is measured against the baseline of its time")
    func drift() {
        var run = FlythroughRun(route: line, passes: ["baseline", "no shadows", "no grass"])
        run.settleSeconds = 0
        // Everything 1 ms slower each pass; switching shadows off saves 3, grass nothing.
        let saving = ["baseline": 0.0, "no shadows": 3, "no grass": 0, FlythroughRun.baselineAgain: 0]
        while !run.isFinished {
            let name = run.passes[run.pass]
            run.record(FrameTimes(interval: 16, cpu: 8 + Double(run.pass) - saving[name]!), seconds: 1)
        }
        let report = run.report
        #expect(report.drift == 3)
        #expect(abs(report.saving(pass: 1) - 3) < 1e-9 && abs(report.saving(pass: 2)) < 1e-9)
        #expect(report.text(title: "Test").contains("drift 3.0 ms"))
    }

    @Test("The headline is the mean of what each frame cost — the larger of its CPU and GPU work")
    func summary() {
        #expect(FlythroughReport.cost(FrameTimes(interval: 16.7, cpu: 4, gpu: 9)) == 9)
        #expect(FlythroughReport.cost(FrameTimes(interval: 8.3, cpu: 6, gpu: nil)) == 6)
        let summary = FlythroughReport.Summary((1...100).map(Double.init))
        #expect(summary.mean == 50.5 && summary.worst == 100 && summary.p95 == 95 && summary.frames == 100)
        var run = FlythroughRun(route: line)
        run.settleSeconds = 0
        while !run.isFinished { run.record(FrameTimes(interval: 16.7, cpu: 4, gpu: 6), seconds: 0.5) }
        let text = run.report.text(title: "Test", settings: "High, 4×")
        #expect(text.contains("WHOLE ROUTE  cost mean 6.0 ms (167 fps)") && text.contains("High, 4×"))
        #expect(text.contains("0,0 -> 100,0") && text.contains("100,0 -> 100,50"))
    }

    /// A game that draws nothing and remembers where the camera was put.
    private final class Still: GameLoop {
        var poses: [Flythrough.Pose] = []
        func beginFrame() {}
        func step(deltaTime: Float) {}
        func viewportSizeChanged(width: Int, height: Int) {}
        func encode(into encoder: MTL4RenderCommandEncoder, frameSlot: Int, interpolation: Float) {}
    }

    @Test("Flown off screen: every frame drawn, the GPU's time for each, and the passes switched in turn")
    @MainActor
    func offScreen() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.supportsFamily(.metal4) else { return }
        let renderer = try FrameRenderer(device: device)
        let game = Still()
        renderer.game = game
        let short = Flythrough(waypoints: [SIMD2(0, 0), SIMD2(20, 0)], speed: 20)
        var switched: [String?] = []
        let report = renderer.flyThrough(short, passes: ["baseline", "no sky"], width: 64, height: 64, framesPerSecond: 30,
                                         ground: { _, _ in 0 }, place: { game.poses.append($0) },
                                         switchPass: { switched.append($0) })
        #expect(switched == ["baseline", "no sky", FlythroughRun.baselineAgain, nil])
        #expect((0..<3).allSatisfy { report.frames(pass: $0).count == 30 }, "a second of route at 30 fps, each pass")
        #expect(report.frames(pass: 0).allSatisfy { $0.gpu != nil && $0.interval > 0 && $0.cpu > 0 })
        #expect(game.poses.first?.eye == SIMD3(0, 3.5, 0) && game.poses.contains { $0.eye.x > 19 })
        #expect(renderer.lastFrameTimes.gpu != nil)
        let baseline = FlythroughReport(route: report.route, passes: ["baseline"], samples: [report.samples[0]],
                                        offScreen: report.offScreen)
        #expect(baseline.text(title: "Test").contains("each drawn and waited for"))
    }
}

/// A frame's GPU time is its share of the GPU's busy time, not its start to end.
@Suite("GPU time")
struct FrameGPUClockTests {
    @Test("Frames that overlap on the GPU are not counted twice")
    func overlap() {
        let clock = FrameGPUClock()
        clock.record(frame: 0, start: 1.000, end: 1.010)
        clock.record(frame: 1, start: 1.005, end: 1.018)   // began while frame 0 was still running
        clock.record(frame: 2, start: 1.030, end: 1.036)   // the GPU idle before it
        #expect(abs(clock.milliseconds(forFrame: 0)! - 10) < 1e-6)
        #expect(abs(clock.milliseconds(forFrame: 1)! - 8) < 1e-6, "only what it added after frame 0 ended")
        #expect(abs(clock.milliseconds(forFrame: 2)! - 6) < 1e-6)
    }
}
