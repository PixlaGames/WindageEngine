//
//  MemoryUse.swift
//  WindageEngine
//

import Darwin
import Metal

/// **What the app holds in memory, measured from inside it** — for a statistics readout, so that turning a setting
/// down shows what it saved rather than what it was guessed to.
///
/// The **footprint** is the number Activity Monitor shows as Memory and the one macOS judges an app by when memory
/// runs short: everything the process has dirtied, **including what Metal holds for it** — on Apple silicon the GPU
/// and the CPU share one memory, so a texture is part of the app's footprint like any array. The **graphics** figure is
/// Metal's own count of what this device has allocated for the process, and so a part of the footprint, not beside it;
/// the **budget** is how much Metal recommends a process keep resident on this Mac before it starts paging.
public nonisolated struct MemoryUse: Sendable, Equatable {
    /// Bytes of the process's physical footprint — Activity Monitor's Memory column; 0 if it could not be read.
    public var footprint: Int
    /// Bytes Metal has allocated on this device for the process.
    public var graphics: Int
    /// Bytes Metal recommends a process keep resident on this device.
    public var graphicsBudget: Int

    public init(footprint: Int, graphics: Int, graphicsBudget: Int) {
        self.footprint = footprint
        self.graphics = graphics
        self.graphicsBudget = graphicsBudget
    }

    /// The process as it stands, against `device`. Cheap enough to take a few times a second.
    public static func measure(device: MTLDevice) -> MemoryUse {
        MemoryUse(footprint: footprint() ?? 0, graphics: device.currentAllocatedSize,
                  graphicsBudget: Int(clamping: device.recommendedMaxWorkingSetSize))
    }

    /// The share of the budget the graphics allocations take, 0 to 1 and beyond; 0 when the device gives no budget.
    public var graphicsShare: Double {
        graphicsBudget > 0 ? Double(graphics) / Double(graphicsBudget) : 0
    }

    /// The process's physical footprint in bytes, from the kernel's own accounting; nil if the kernel refused.
    public static func footprint() -> Int? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : nil
    }

    /// The bytes `allocations` take on the GPU, each counted once — a texture two materials share is one texture.
    public static func bytes(of allocations: [any MTLAllocation]) -> Int {
        var seen = Set<ObjectIdentifier>()
        var total = 0
        for allocation in allocations where seen.insert(ObjectIdentifier(allocation)).inserted {
            total += allocation.allocatedSize
        }
        return total
    }
}

/// **Frame times averaged over a stretch of frames**, for a readout that a person can read: one frame's numbers
/// change faster than the eye, and the frame a readout happens to sample is as likely to be the odd one as not.
public nonisolated struct FrameTimesAverage: Sendable, Equatable {
    /// Frames added since the last reset.
    public private(set) var frames = 0
    private var interval = 0.0
    private var cpu = 0.0
    private var gpu = 0.0
    private var gpuFrames = 0
    /// The slowest frame's interval since the last reset, in milliseconds — a hitch an average smooths away.
    public private(set) var slowest = 0.0

    public init() {}

    /// One more frame. A first frame's interval of 0 — nothing came before it — is not counted.
    public mutating func add(_ times: FrameTimes) {
        guard times.interval > 0 else { return }
        frames += 1
        interval += times.interval
        cpu += times.cpu
        slowest = max(slowest, times.interval)
        if let time = times.gpu {
            gpu += time
            gpuFrames += 1
        }
    }

    /// The average frame since the last reset; nil if nothing has been added. GPU is nil until a frame reported one.
    public var mean: FrameTimes? {
        guard frames > 0 else { return nil }
        let count = Double(frames)
        return FrameTimes(interval: interval / count, cpu: cpu / count,
                          gpu: gpuFrames > 0 ? gpu / Double(gpuFrames) : nil)
    }

    /// Starts a new stretch.
    public mutating func reset() { self = FrameTimesAverage() }
}
