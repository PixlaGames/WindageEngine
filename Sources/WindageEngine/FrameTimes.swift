//
//  FrameTimes.swift
//  WindageEngine
//

import Foundation
import Synchronization

/// **What one frame cost** — three numbers, because one cannot say it (2026-10-27).
///
/// The **interval** is what a player sees: the time from one shown frame to the next. It is paced by the display, so a
/// frame that needed 4 ms reads the same 8.3 ms as one that needed 8 at 120 Hz — fine for "is it smooth", useless for
/// "how much room is left". The **CPU** time is the engine's and the game's own work for the frame — stepping and
/// encoding, not waiting for the GPU to free a frame in flight. The **GPU** time is how long the GPU spent on it, from
/// Metal's commit feedback. The frame costs the larger of the two; the interval is what that came to on this display.
public nonisolated struct FrameTimes: Sendable, Equatable {
    /// Milliseconds from the previous frame shown to this one; 0 for the first.
    public var interval: Double = 0
    /// Milliseconds of work on the CPU: the game's steps and the frame's encoding.
    public var cpu: Double = 0
    /// Milliseconds the GPU spent on the most recent frame it has finished — a frame or two behind, since a frame in flight
    /// has not finished yet. Nil until one has. **Its own share of the GPU's busy time**: frames in flight overlap on the
    /// GPU, and each one's start-to-end counted the overlap twice — 19.9 ms of "GPU" a frame against frames shown every
    /// 17.8 (2026-10-27). Only the time after the previous frame finished is this frame's.
    public var gpu: Double?

    public init(interval: Double = 0, cpu: Double = 0, gpu: Double? = nil) {
        self.interval = interval
        self.cpu = cpu
        self.gpu = gpu
    }
}

/// The GPU times Metal hands back from another thread as each frame finishes, kept for the renderer to read.
nonisolated final class FrameGPUClock: Sendable {
    private let times = Mutex<[Int: Double]>([:])
    private let newest = Mutex<Double?>(nil)
    /// When the GPU finished the last frame it reported, in seconds.
    private let lastEnd = Mutex<Double>(0)

    /// Called from Metal's feedback handler with the frame's GPU start and end, in seconds: what it adds to the GPU's busy
    /// time is from the later of its start and the previous frame's end.
    func record(frame: Int, start: Double, end: Double) {
        let milliseconds = lastEnd.withLock { previous -> Double in
            let busy = max(end - max(start, previous), 0)
            previous = max(previous, end)
            return busy * 1000
        }
        times.withLock {
            $0[frame] = milliseconds
            // A few seconds of frames is all anyone reads back.
            if $0.count > 512 { $0 = $0.filter { $0.key > frame - 256 } }
        }
        newest.withLock { $0 = milliseconds }
    }

    /// The newest GPU time finished.
    var latest: Double? { newest.withLock { $0 } }

    /// A given frame's GPU time, once it has finished.
    func milliseconds(forFrame frame: Int) -> Double? { times.withLock { $0[frame] } }
}
