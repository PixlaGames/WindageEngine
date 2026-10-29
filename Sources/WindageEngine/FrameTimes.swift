//
//  FrameTimes.swift
//  WindageEngine
//

import Foundation
import Metal
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

    /// **A frame the GPU failed** (2026-10-29): Metal's error for it, kept so a wait for that frame can stop waiting.
    struct Fault: Sendable, Equatable {
        let frame: Int
        let code: Int
        let description: String
        /// Metal has stopped running this process's work after earlier faults — nothing committed from here signals.
        let revoked: Bool
    }
    private let faults = Mutex<[Int: Fault]>([:])
    private let firstFault = Mutex<Fault?>(nil)

    /// Called from Metal's feedback handler when a committed frame failed.
    func record(frame: Int, error: NSError) {
        let fault = Self.fault(frame: frame, error: error)
        faults.withLock {
            $0[frame] = fault
            if $0.count > 512 { $0 = $0.filter { $0.key > frame - 256 } }
        }
        firstFault.withLock { if $0 == nil { $0 = fault } }
    }

    /// **What Metal's error says, which is in the errors under it**: Metal 4 reports a failed commit as
    /// `MTL4CommandQueueErrorDomain` 1 with "The operation couldn't be completed", and the page fault, or the access
    /// revoked after one, as underlying errors (`NSUnderlyingErrorKey`, `NSMultipleUnderlyingErrorsKey`).
    static func fault(frame: Int, error: NSError) -> Fault {
        var all: [NSError] = []
        func gather(_ error: NSError) {
            all.append(error)
            if let under = error.userInfo[NSUnderlyingErrorKey] as? NSError { gather(under) }
            for under in error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] ?? [] { gather(under) }
        }
        gather(error)
        let revoked = all.contains {
            ($0.domain == MTL4CommandQueueErrorDomain && $0.code == MTL4CommandQueueError.accessRevoked.rawValue)
                || ($0.domain == MTLCommandBufferErrorDomain && $0.code == MTLCommandBufferError.Code.accessRevoked.rawValue)
        }
        // The first message that says something: the top error's is Foundation's generic one.
        let said = all.compactMap { $0.userInfo[NSLocalizedDescriptionKey] as? String }.first
        return Fault(frame: frame, code: error.code, description: said ?? error.localizedDescription, revoked: revoked)
    }

    /// The fault Metal reported for a frame, if it failed.
    func fault(forFrame frame: Int) -> Fault? { faults.withLock { $0[frame] } }
    /// The first fault this renderer saw — the cause, when later frames are refused because of it.
    var first: Fault? { firstFault.withLock { $0 } }
}
