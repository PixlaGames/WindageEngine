//
//  FrameCheck.swift
//  WindageEngine
//

import CoreGraphics
import Foundation
import ImageIO
import Metal
import QuartzCore
import UniformTypeIdentifiers

/// **A frame drawn off screen, for a check nobody has to watch** — written out as PNG, or timed.
///
/// Through the same passes as the screen (``render(into:)``), so what comes out is what a player would see, whatever
/// the window is doing: a window tucked away by Stage Manager, minimised or behind another gives a screen capture a
/// thumbnail or nothing, and gives this the frame. Every title wanted the same few lines for it, so they are here once.
extension FrameRenderer {
    /// One frame at this size, as PNG data (sRGB), or nil if it could not be drawn or encoded.
    public func pngFrame(width: Int, height: Int) -> Data? {
        guard let texture = frameCheckTarget(width: width, height: height) else { return nil }
        defer {
            residencySet.removeAllocation(texture)
            commitResidency()
        }
        render(into: texture)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent),
              let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// `count` frames at this size, each drawn and waited for, in milliseconds, **sorted** — read the median and the
    /// fastest, not an average: a frame or two of something else on the machine moves an average more than the effect
    /// being measured. Warmed up first, so pipelines and residency are not in the numbers.
    public func timeFrames(width: Int, height: Int, count: Int = 60, warmUp: Int = 4) -> [Double] {
        guard let texture = frameCheckTarget(width: width, height: height) else { return [] }
        defer {
            residencySet.removeAllocation(texture)
            commitResidency()
        }
        for _ in 0..<warmUp { render(into: texture) }
        var times: [Double] = []
        for _ in 0..<max(count, 1) {
            let start = CACurrentMediaTime()
            render(into: texture)
            times.append((CACurrentMediaTime() - start) * 1000)
        }
        return times.sorted()
    }

    /// Writes PNG data to a file, or to standard output for `-` — the only place a sandboxed app can hand a file to
    /// whoever ran it. True when written.
    public static func writeFrameCheck(_ png: Data, to path: String) -> Bool {
        if path == "-" {
            FileHandle.standardOutput.write(png)
            return true
        }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    private func frameCheckTarget(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: FrameRenderer.colorPixelFormat,
                                                                  width: max(width, 1), height: max(height, 1),
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        residencySet.addAllocation(texture)
        commitResidency()
        return texture
    }
}
