//
//  TextureUploader.swift — per-frame CPU pictures onto the GPU without churn.
//
//  Purpose : `MetalContext.makeTexture(from:)` allocates a new texture, copies the
//            1.38 MB frame, and swaps R/B in a per-pixel loop. Fine once; on the frame
//            path it is four sources × 30 fps ≈ 165 MB/s through the GPU allocator —
//            the churn that fragments IOSurface/wired memory over a long show — plus a
//            CPU pixel loop CLAUDE.md forbids. This reuses two textures and swizzles
//            with Accelerate (SIMD) into a reused buffer.
//  Inputs  : an RGBA `ImageBuffer` per call.
//  Outputs : a BGRA texture, the same format and usage `makeTexture` produces, so
//            blits (freeze, readback) keep working unchanged.
//  Connects: ClipSourceNode, CaptureSourceNode, BusCodecNode, EmulatedTitlerNode.
//  Extend  : one uploader per producing node; never share one between nodes.
//
//  WHY TWO TEXTURES. The engine fences once per frame (`MetalContext.waitForIdle`), and
//  previews present AFTER that fence, so a texture handed out this frame may still be
//  read by a preview's GPU pass when the next frame begins. Alternating means a texture
//  is only rewritten two uploads later — after a fence that covered every pass that
//  could read it.
//

import Accelerate
import Foundation
import Metal

/// Uploads CPU frames into a reused pair of textures.
public final class TextureUploader {

    private let context: MetalContext
    private let label: String
    private var textures: [MTLTexture?] = [nil, nil]
    private var next = 0
    private var scratch: [UInt8] = []

    public init(context: MetalContext, label: String) {
        self.context = context
        self.label = label
    }

    /// Uploads `image`, returning a texture valid until the upload after next.
    public func upload(_ image: ImageBuffer) -> MTLTexture? {
        let slot = next
        next = 1 - next

        if textures[slot]?.width != image.width || textures[slot]?.height != image.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: MetalContext.pixelFormat,
                width: image.width, height: image.height, mipmapped: false)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .managed
            guard let texture = context.device.makeTexture(descriptor: descriptor) else {
                Log.error(.render, "could not allocate upload texture '\(label)'")
                return nil
            }
            texture.label = "\(label)-\(slot)"
            textures[slot] = texture
        }
        guard let texture = textures[slot] else { return nil }

        let count = image.pixels.count
        if scratch.count != count { scratch = [UInt8](repeating: 0, count: count) }

        // RGBA -> BGRA: destination channel i takes source channel map[i].
        let map: [UInt8] = [2, 1, 0, 3]
        let permuted: vImage_Error = image.pixels.withUnsafeBytes { source in
            scratch.withUnsafeMutableBytes { destination in
                var src = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: source.baseAddress!),
                    height: vImagePixelCount(image.height), width: vImagePixelCount(image.width),
                    rowBytes: image.bytesPerRow)
                var dst = vImage_Buffer(
                    data: destination.baseAddress!,
                    height: vImagePixelCount(image.height), width: vImagePixelCount(image.width),
                    rowBytes: image.bytesPerRow)
                return vImagePermuteChannels_ARGB8888(&src, &dst, map, vImage_Flags(kvImageNoFlags))
            }
        }
        guard permuted == kvImageNoError else {
            Log.error(.render, "'\(label)' channel swizzle failed (\(permuted)); keeping last frame")
            return nil
        }

        scratch.withUnsafeBytes { raw in
            texture.replace(
                region: MTLRegionMake2D(0, 0, image.width, image.height),
                mipmapLevel: 0, withBytes: raw.baseAddress!, bytesPerRow: image.bytesPerRow)
        }
        return texture
    }
}
