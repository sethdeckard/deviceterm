// SPDX-License-Identifier: GPL-3.0-or-later
//
// SimulatorMetalRenderer: the Metal draw path for a simulator /
// device pane, split out of SimulatorContentView. It owns the command
// queue + pipeline state and the shader, and renders one IOSurface into
// an MTKView's current drawable each frame: aspect-fit inside the
// wrapper's bezel inset, UV counter-rotation so rotated content shows
// upright, and an SDF rounded-screen discard. The view keeps the live
// orientation / inset / surface state (its gesture code reads them too)
// and passes them in per frame; nothing here touches input.

import DaemonProtocol
import MetalKit
import SurfaceTrace

@MainActor
final class SimulatorMetalRenderer {
    /// Shader constants. Layout MUST match `Params` in the
    /// shader source, where every field is 16 bytes (Metal struct
    /// alignment). Marshalled raw via `setVertexBytes` so the
    /// layout is the source of truth.
    private struct RenderParams {
        var imageRect: SIMD4<Float>
        var uvRotation: SIMD4<Float>
        /// `(screenWidthPx, screenHeightPx, cornerRadiusPx, 0)`.
        /// The fragment shader uses these to round the screen's
        /// corners via SDF discard (CAShapeLayer masks on
        /// CAMetalLayer don't compose reliably with Metal
        /// drawable presentation; SDF in shader is the
        /// guaranteed path).
        var screen: SIMD4<Float>
        /// `(drawableWidthPx, drawableHeightPx, 0, 0)`. The
        /// fragment shader needs the framebuffer size to recover
        /// its position relative to the screen center.
        var drawable: SIMD4<Float>
    }

    /// Concurrent queue for the off-by-default post-completion trace scans,
    /// so a delayed scan never runs on Metal's completion thread and delays
    /// overlap instead of serializing into a backlog.
    /// `nonisolated` because the Metal completion handler that uses it is a
    /// `Sendable` closure running off the main actor; both Dispatch types are
    /// themselves `Sendable`, so no unsafe opt-out is needed.
    nonisolated private static let traceScanQueue = DispatchQueue(
        label: "deviceterm.surface-trace.scan",
        attributes: .concurrent
    )
    /// Bounds the number of in-flight delayed scans (each retains an
    /// IOSurface for the delay); excess frames drop their trace rather than
    /// growing an unbounded backlog.
    nonisolated private static let traceInFlight = DispatchSemaphore(value: 32)

    private let queue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        queue = device.makeCommandQueue()
        buildPipeline(device: device, pixelFormat: pixelFormat)
    }

    /// Render `surface` into `view`'s current drawable. `orientation`
    /// counter-rotates UV sampling so rotated content shows upright;
    /// `displayInset` reserves the bezel margin; `screenCornerRadius`
    /// drives the rounded-screen SDF mask. With no surface / pipeline
    /// yet, presents an empty drawable so the view doesn't show garbage
    /// on the first frames. Returns whether a supplied `trace` was
    /// installed (i.e. this draw reached commit), so the caller only
    /// retires a frame's trace once it is actually armed.
    func render(
        lease: SurfaceLease?,
        orientation: Orientation,
        displayInset: CGFloat,
        screenCornerRadius: CGFloat,
        in view: MTKView,
        trace: SurfaceConsumerTrace? = nil
    ) -> Bool {
        guard let drawable = view.currentDrawable,
            let descriptor = view.currentRenderPassDescriptor,
            let pipeline = pipelineState,
            let queue,
            let device = view.device,
            let lease
        else {
            // No surface yet, so present an empty drawable and the view
            // doesn't show garbage on first frames.
            if let drawable = view.currentDrawable,
                let descriptor = view.currentRenderPassDescriptor,
                let queue {
                let commandBuffer = queue.makeCommandBuffer()
                if let enc = commandBuffer?.makeRenderCommandEncoder(
                    descriptor: descriptor
                ) {
                    enc.endEncoding()
                }
                commandBuffer?.present(drawable)
                commandBuffer?.commit()
            }
            return false
        }
        let surface = lease.surface
        let texDesc = MTLTextureDescriptor()
        texDesc.pixelFormat = .bgra8Unorm
        texDesc.width = IOSurfaceGetWidth(surface)
        texDesc.height = IOSurfaceGetHeight(surface)
        texDesc.usage = [.shaderRead]
        texDesc.storageMode = .shared
        guard let texture = device.makeTexture(
            descriptor: texDesc,
            iosurface: surface,
            plane: 0
        ) else { return false }
        let texW = CGFloat(texDesc.width)
        let texH = CGFloat(texDesc.height)
        let viewW = max(1, view.drawableSize.width)
        let viewH = max(1, view.drawableSize.height)
        // Effective texture aspect: landscape orientations swap
        // width/height because CoreSimulator keeps delivering the
        // surface at portrait pixel dimensions even when the device
        // is rotated. The shader's UV rotation makes the rendered
        // content upright; aspect fitting against the swapped
        // dimensions keeps the quad shaped like the rotated content
        // rather than letterboxing landscape into a portrait box.
        let isLandscape = orientation == .landscapeLeft
            || orientation == .landscapeRight
        let effectiveTexW = isLandscape ? texH : texW
        let effectiveTexH = isLandscape ? texW : texH
        let texAspect = effectiveTexW / effectiveTexH
        // Reserve `displayInset`pt on each side for the wrapper's
        // bezel, converting points → drawable pixels via the view's
        // backing scale so the inset is consistent regardless of
        // Retina factor. Shrink the usable rect, aspect-fit inside
        // it, then re-express the screen rect as NDC against the
        // full drawableSize so the freed margin becomes
        // transparent letterbox (bezel paints through it).
        let backing = max(1, view.window?.backingScaleFactor ?? 2)
        let insetPx = displayInset * backing
        let usableW = max(1, viewW - 2 * insetPx)
        let usableH = max(1, viewH - 2 * insetPx)
        let usableAspect = usableW / usableH
        let screenW: CGFloat
        let screenH: CGFloat
        if usableAspect > texAspect {
            screenH = usableH
            screenW = usableH * texAspect
        } else {
            screenW = usableW
            screenH = usableW / texAspect
        }
        let ndcW = Float(screenW / viewW)
        let ndcH = Float(screenH / viewH)
        // Screen-corner radius in pixels for the fragment shader's
        // SDF rounding. Clamp to half the smaller screen dimension
        // so an absurdly-large radius can't invert the corner.
        let cornerPx = max(0, min(
            screenCornerRadius * backing,
            min(screenW, screenH) * 0.5
        ))
        var params = RenderParams(
            imageRect: SIMD4<Float>(-ndcW, -ndcH, ndcW, ndcH),
            uvRotation: uvRotation(for: orientation),
            screen: SIMD4<Float>(Float(screenW), Float(screenH), Float(cornerPx), 0),
            drawable: SIMD4<Float>(Float(viewW), Float(viewH), 0, 0)
        )
        guard let commandBuffer = queue.makeCommandBuffer(),
            let enc = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor
            )
        else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.setVertexBytes(
            &params,
            length: MemoryLayout<RenderParams>.size,
            index: 0
        )
        enc.setFragmentBytes(
            &params,
            length: MemoryLayout<RenderParams>.size,
            index: 0
        )
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
        commandBuffer.present(drawable)
        // Off-by-default: once the command buffer reaches a terminal state,
        // stamp the completion time (the join timestamp), then
        // (optionally after an adversarial delay that lets the daemon reuse
        // the slot) scan the surface and record what we observed against the
        // generation we intended to render.
        // Reserve an in-flight slot *before* reporting the trace installed,
        // so the caller never retires a sequence whose scan we then silently
        // drop. At capacity the trace isn't installed and the caller retries
        // it on a later draw.
        var traceInstalled = false
        if let trace, Self.traceInFlight.wait(timeout: .now()) == .success {
            traceInstalled = true
            // The closure captures `sampled`, which retains the IOSurface
            // through the completion handler and the delayed scan; the
            // content view may have replaced its surface by then. The delay
            // + scan run on a concurrent background queue (never Metal's
            // completion thread), so a long delay can't stall Metal.
            nonisolated(unsafe) let sampled = surface
            commandBuffer.addCompletedHandler { _ in
                let completedAt = DispatchTime.now().uptimeNanoseconds
                let deadline = DispatchTime.now() + .nanoseconds(Int(trace.delayNanoseconds))
                Self.traceScanQueue.asyncAfter(deadline: deadline) {
                    let scanned = SurfacePixelStamp.scan(sampled)
                    trace.sink.record(
                        SurfaceTraceRow(
                            role: "consumer",
                            paneId: trace.paneId,
                            traceId: trace.expectedTraceId,
                            monotonicNanoseconds: completedAt,
                            observedTraceId: UInt64(scanned.reference),
                            mismatchRows: scanned.mismatchRows
                        )
                    )
                    Self.traceInFlight.signal()
                }
            }
        }
        // The ownership edge: retain the lease until this command buffer
        // completes. For a leased device frame that's what keeps its pool
        // slot from being recycled while the GPU is still sampling it; an
        // unleased frame is retained the same way but has no release
        // bookkeeping, so it's a cheap no-op. Metal fires completion
        // handlers even on error/timeout, so the ref is always dropped.
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(lease) {} }
        commandBuffer.commit()
        return traceInstalled
    }

    private func uvRotation(for orientation: Orientation) -> SIMD4<Float> {
        switch orientation {
        case .portrait:
            return SIMD4<Float>(1, 0, 0, 1)

        case .landscapeLeft:
            return SIMD4<Float>(0, -1, 1, 0)

        case .portraitUpsideDown:
            return SIMD4<Float>(-1, 0, 0, -1)

        case .landscapeRight:
            return SIMD4<Float>(0, 1, -1, 0)
        }
    }

    private func buildPipeline(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        // `Params.uvRotation` packs a 2x2 rotation matrix as
        // (m00, m01, m10, m11), applied to (uv - 0.5) so rotation
        // happens around the texture center, then re-translated.
        // CoreSimulator delivers the IOSurface at portrait pixel
        // dimensions even when the device is rotated; this shader-
        // side counter-rotation undoes that so landscape content
        // shows upright. Identity for portrait (no-op).
        // Params layout MUST stay in sync with the Swift
        // `RenderParams` struct (each field 16 bytes).
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct VOut { float4 position [[position]]; float2 uv; };
        struct Params {
            float4 imageRect;
            float4 uvRotation;
            float4 screen;   // (screenWpx, screenHpx, cornerPx, _)
            float4 drawable; // (drawableWpx, drawableHpx, _, _)
        };
        vertex VOut vmain(uint vid [[vertex_id]], constant Params& p [[buffer(0)]]) {
            float2 corners[6] = {
                {p.imageRect.x, p.imageRect.y},
                {p.imageRect.z, p.imageRect.y},
                {p.imageRect.x, p.imageRect.w},
                {p.imageRect.z, p.imageRect.y},
                {p.imageRect.z, p.imageRect.w},
                {p.imageRect.x, p.imageRect.w}
            };
            float2 uvs[6] = { {0,1}, {1,1}, {0,0}, {1,1}, {1,0}, {0,0} };
            float2 centered = uvs[vid] - float2(0.5, 0.5);
            float2x2 rot = float2x2(
                float2(p.uvRotation.x, p.uvRotation.z),
                float2(p.uvRotation.y, p.uvRotation.w)
            );
            float2 rotated = rot * centered + float2(0.5, 0.5);
            VOut o; o.position = float4(corners[vid], 0, 1); o.uv = rotated;
            return o;
        }
        fragment float4 fmain(VOut in [[stage_in]],
                              constant Params& p [[buffer(0)]],
                              texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            // Rounded-screen SDF discard. The fragment's [[position]]
            // is in framebuffer pixel coords; recover the offset from
            // the screen's center using the drawable size. The SDF
            // gives the signed distance to the rounded-rect edge:
            // positive outside → discard so the bezel below shows
            // through; negative or zero inside → sample texture.
            // Skip entirely when cornerPx==0 (tv, or before the
            // wrapper has pushed a frame).
            float2 fragCoord = in.position.xy;
            float2 center = p.drawable.xy * 0.5;
            float2 fromCenter = fragCoord - center;
            float2 halfScreen = p.screen.xy * 0.5;
            float radius = p.screen.z;
            if (radius > 0.0) {
                float2 q = abs(fromCenter) - halfScreen + float2(radius);
                float dist = min(max(q.x, q.y), 0.0)
                    + length(max(q, float2(0))) - radius;
                if (dist > 0.0) {
                    discard_fragment();
                }
            }
            return tex.sample(s, in.uv);
        }
        """
        do {
            let lib = try device.makeLibrary(source: source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vmain")
            desc.fragmentFunction = lib.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = pixelFormat
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
        } catch {
            NSLog("deviceterm: metal pipeline setup failed: \(error)")
        }
    }
}
