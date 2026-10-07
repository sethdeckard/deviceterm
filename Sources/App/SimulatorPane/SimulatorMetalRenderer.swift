// SPDX-License-Identifier: GPL-3.0-or-later

import DaemonProtocol
import MetalKit
import SurfaceTrace

/// The Metal draw path for a simulator /
/// device pane, split out of SimulatorContentView. It owns the command
/// queue + pipeline state and the shader, and renders one IOSurface into
/// an MTKView's current drawable on each draw: aspect-fit inside the
/// wrapper's bezel inset, UV counter-rotation so rotated content shows
/// upright, and an SDF rounded-screen discard. The view keeps the live
/// orientation / inset / surface state (its gesture code reads them too)
/// and passes them in per draw; nothing here touches input. The rendered
/// image is determined by the surface, orientation, bezel geometry,
/// drawable size, and backing scale alone, which is what lets the view
/// draw only when one of them changes or when mounting supplies a
/// drawable that needs presenting.
@MainActor
final class SimulatorMetalRenderer {
    /// Shader constants. Layout MUST match `Params` in the
    /// shader source, where every field is 16 bytes (Metal struct
    /// alignment). Marshalled raw via `setVertexBytes` so the
    /// layout is the source of truth.
    private struct RenderParams {
        var imageRect: SIMD4<Float>
        var uvRotation: SIMD4<Float>
        /// `(screenWidthPx, screenHeightPx, 0, 0)`.
        /// The fragment shader uses these with `corners` to round the
        /// screen via SDF discard (CAShapeLayer masks on
        /// CAMetalLayer don't compose reliably with Metal
        /// drawable presentation; SDF in shader is the
        /// guaranteed path).
        var screen: SIMD4<Float>
        /// `(topLeftPx, topRightPx, bottomLeftPx, bottomRightPx)`, in the
        /// order the viewer sees them. Four because a display is not
        /// always a rounded rectangle; the fragment picks the one for the
        /// quadrant it is in.
        var corners: SIMD4<Float>
        /// `(drawableWidthPx, drawableHeightPx, 0, 0)`. The
        /// fragment shader needs the framebuffer size to recover
        /// its position relative to the screen center.
        var drawable: SIMD4<Float>
    }

    /// One corner of a bent half. Layout MUST match `CVertex` in the shader
    /// source, where both fields are 16 bytes (Metal struct alignment).
    /// Marshalled raw via `setVertexBytes`, so the layout is the contract.
    private struct CreaseVertex {
        /// `(ndcX, ndcY, u, v)`, the projected position and the texture
        /// coordinate before the orientation rotation is applied.
        var positionUV: SIMD4<Float>
        /// `(localX, localY, w, 0)`. `local` is the corner's position in the
        /// *flat* picture, in pixels from its centre, which is what the
        /// rounded-screen SDF measures so the corners follow the bend. `w` is
        /// the clip-space divisor: a bent half is a trapezoid on screen, and
        /// without a real `w` the rasterizer interpolates its texture affinely
        /// and the picture warps across the fold. The last lane pads the
        /// field to 16 bytes.
        var localW: SIMD4<Float>
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
    /// Draws the two halves of a creased picture. Kept separate from
    /// `pipelineState` so a flat picture goes through the single-quad path
    /// whatever the fold is doing.
    private var creasePipelineState: MTLRenderPipelineState?

    init(device: MTLDevice, pixelFormat: MTLPixelFormat) {
        queue = device.makeCommandQueue()
        buildPipeline(device: device, pixelFormat: pixelFormat)
    }

    /// The twelve corners of a creased picture: two triangles per half.
    ///
    /// `ndc` is the flat picture's half-extents in normalized device
    /// coordinates; `screen` is its full size in pixels. `vertical` says which
    /// way the crease runs, which decides whether the fold divides x or y;
    /// everything below is written in the crease's own axes (*across* it and
    /// *along* it) and mapped out at the end, so the two cases share one piece
    /// of geometry.
    ///
    /// Texture coordinates come from which corner of the half a vertex is,
    /// never from where the projection put it: the picture is a rectangle
    /// glued to a shape that is no longer rectangular.
    private static func creaseVertices(
        crease: FoldCreaseGeometry.Crease,
        vertical: Bool,
        ndc: SIMD2<Float>,
        screen: SIMD2<Float>
    ) -> [CreaseVertex] {
        let acrossNdc = vertical ? ndc.x : ndc.y
        let alongNdc = vertical ? ndc.y : ndc.x
        let acrossPixels = (vertical ? screen.x : screen.y) / 2
        let alongPixels = (vertical ? screen.y : screen.x) / 2
        let scale = Float(crease.scale)
        let outerAcross = acrossNdc * Float(crease.outerAcross) * scale
        let outerAlong = alongNdc * Float(crease.outerAlong) * scale
        let creaseAlong = alongNdc * scale
        // The crease's clip divisor, relative to the outer edges' one. The
        // crease sits behind them by the edges' magnification, which is what
        // makes it the shorter edge.
        let creaseW = Float(crease.outerAlong)

        /// One corner, in the crease's axes. `across` is -1 on the leading
        /// half's outer edge, 0 on the crease itself, +1 on the trailing
        /// half's; `along` is -1 or +1 down the crease.
        func corner(across: Float, along: Float) -> CreaseVertex {
            let onCrease = across == 0
            let acrossNdcPosition = across * outerAcross
            let alongNdcPosition = along * (onCrease ? creaseAlong : outerAlong)
            let position = vertical
                ? SIMD2<Float>(acrossNdcPosition, alongNdcPosition)
                : SIMD2<Float>(alongNdcPosition, acrossNdcPosition)
            let local = vertical
                ? SIMD2<Float>(across * acrossPixels, along * alongPixels)
                : SIMD2<Float>(along * alongPixels, across * acrossPixels)
            // Texture coordinates follow the flat picture: the x unit runs
            // with u, and the y unit against v, matching the single-quad path.
            let unit = vertical
                ? SIMD2<Float>(across, along)
                : SIMD2<Float>(along, across)
            let uvPoint = SIMD2<Float>((unit.x + 1) / 2, (1 - unit.y) / 2)
            return CreaseVertex(
                positionUV: SIMD4<Float>(position.x, position.y, uvPoint.x, uvPoint.y),
                localW: SIMD4<Float>(local.x, local.y, onCrease ? creaseW : 1, 0)
            )
        }

        func half(outerSide: Float) -> [CreaseVertex] {
            let outerLow = corner(across: outerSide, along: -1)
            let outerHigh = corner(across: outerSide, along: 1)
            let creaseLow = corner(across: 0, along: -1)
            let creaseHigh = corner(across: 0, along: 1)
            return [outerLow, outerHigh, creaseLow, outerHigh, creaseHigh, creaseLow]
        }

        return half(outerSide: -1) + half(outerSide: 1)
    }

    /// Render `surface` into `view`'s current drawable. `orientation`
    /// counter-rotates UV sampling so rotated content shows upright;
    /// `displayInset` reserves the bezel margin; `screenCorners`
    /// drives the rounded-screen SDF mask, one radius per corner. With no surface / pipeline
    /// yet, presents an empty drawable so the view doesn't show garbage
    /// on the first frames. Returns whether a supplied `trace` was
    /// installed (i.e. this draw reached commit), so the caller only
    /// retires a frame's trace once it is actually armed.
    func render(
        lease: SurfaceLease?,
        orientation: Orientation,
        displayInset: CGFloat,
        screenCorners: DeviceBezelLayout.Corners,
        crease: FoldCreaseGeometry.Crease?,
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
        // Screen-corner radii in pixels for the fragment shader's SDF
        // rounding. Each clamps to half the smaller screen dimension so an
        // absurdly-large radius can't invert its corner.
        let cornerLimit = min(screenW, screenH) * 0.5
        func cornerPx(_ radius: CGFloat) -> Float {
            Float(max(0, min(radius * backing, cornerLimit)))
        }
        var params = RenderParams(
            imageRect: SIMD4<Float>(-ndcW, -ndcH, ndcW, ndcH),
            uvRotation: uvRotation(for: orientation),
            screen: SIMD4<Float>(Float(screenW), Float(screenH), 0, 0),
            corners: SIMD4<Float>(
                cornerPx(screenCorners.topLeft),
                cornerPx(screenCorners.topRight),
                cornerPx(screenCorners.bottomLeft),
                cornerPx(screenCorners.bottomRight)
            ),
            drawable: SIMD4<Float>(Float(viewW), Float(viewH), 0, 0)
        )
        guard let commandBuffer = queue.makeCommandBuffer(),
            let enc = commandBuffer.makeRenderCommandEncoder(
                descriptor: descriptor
            )
        else { return false }
        // A creased picture takes the two-quad path, and only when its
        // pipeline built: a foldable on a host where that failed draws flat
        // rather than not at all.
        let bent = crease.flatMap { shape in
            creasePipelineState.map { (shape, $0) }
        }
        enc.setRenderPipelineState(bent?.1 ?? pipeline)
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
        if let (shape, _) = bent {
            let vertical = FoldCreaseGeometry.creaseRunsVertically(in: orientation)
            // The same fit the bezel and the input path apply, measured in
            // drawable pixels rather than points. It is a ratio, so the unit
            // does not change it.
            let fitted = FoldCreaseGeometry.fitted(
                shape,
                picture: CGRect(
                    x: (viewW - screenW) / 2,
                    y: (viewH - screenH) / 2,
                    width: screenW,
                    height: screenH
                ),
                margin: insetPx,
                within: CGRect(x: 0, y: 0, width: viewW, height: viewH),
                vertical: vertical
            )
            var vertices = Self.creaseVertices(
                crease: fitted,
                vertical: vertical,
                ndc: SIMD2<Float>(ndcW, ndcH),
                screen: SIMD2<Float>(Float(screenW), Float(screenH))
            )
            enc.setVertexBytes(
                &vertices,
                length: MemoryLayout<CreaseVertex>.stride * vertices.count,
                index: 1
            )
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        } else {
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
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
        // completes. For a leased frame that's what keeps its pool slot
        // from being recycled while the GPU is still sampling it; an
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
            float4 screen;   // (screenWpx, screenHpx, _, _)
            float4 corners;  // (topLeftPx, topRightPx, bottomLeftPx, bottomRightPx)
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
            // Skip entirely when the radius is 0 (tv, or before the
            // wrapper has pushed a frame).
            float2 fragCoord = in.position.xy;
            float2 center = p.drawable.xy * 0.5;
            float2 fromCenter = fragCoord - center;
            float2 halfScreen = p.screen.xy * 0.5;
            // Framebuffer y grows downward, so a negative offset is the top.
            float radius = (fromCenter.x < 0.0)
                ? ((fromCenter.y < 0.0) ? p.corners.x : p.corners.z)
                : ((fromCenter.y < 0.0) ? p.corners.y : p.corners.w);
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
        // The creased path. Positions arrive already projected, so the vertex
        // shader's only job is to restore the clip divisor the projection
        // divided out: without it the rasterizer interpolates each trapezoid's
        // texture affinely and the picture slides across the fold.
        let creaseSource = """
        struct CVertex { float4 positionUV; float4 localW; };
        struct COut {
            float4 position [[position]];
            float2 uv;
            float2 local;
        };
        vertex COut vcrease(uint vid [[vertex_id]],
                            constant Params& p [[buffer(0)]],
                            constant CVertex *verts [[buffer(1)]]) {
            CVertex v = verts[vid];
            float2 centered = v.positionUV.zw - float2(0.5, 0.5);
            float2x2 rot = float2x2(
                float2(p.uvRotation.x, p.uvRotation.z),
                float2(p.uvRotation.y, p.uvRotation.w)
            );
            float w = v.localW.z;
            COut o;
            o.position = float4(v.positionUV.xy * w, 0, w);
            o.uv = rot * centered + float2(0.5, 0.5);
            o.local = v.localW.xy;
            return o;
        }
        fragment float4 fcrease(COut in [[stage_in]],
                                constant Params& p [[buffer(0)]],
                                texture2d<float> tex [[texture(0)]]) {
            constexpr sampler s(address::clamp_to_edge, filter::linear);
            // Same rounded-screen SDF as the flat path, measured against the
            // corner's place in the unbent picture rather than its place on
            // the framebuffer, so the rounding bends with the panel.
            // `local` is in the picture's own axes, where y grows upward,
            // so the sign test is the other way round from the flat path.
            float radius = (in.local.x < 0.0)
                ? ((in.local.y > 0.0) ? p.corners.x : p.corners.z)
                : ((in.local.y > 0.0) ? p.corners.y : p.corners.w);
            if (radius > 0.0) {
                float2 q = abs(in.local) - p.screen.xy * 0.5 + float2(radius);
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
            let lib = try device.makeLibrary(source: source + creaseSource, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = lib.makeFunction(name: "vmain")
            desc.fragmentFunction = lib.makeFunction(name: "fmain")
            desc.colorAttachments[0].pixelFormat = pixelFormat
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            let creaseDesc = MTLRenderPipelineDescriptor()
            creaseDesc.vertexFunction = lib.makeFunction(name: "vcrease")
            creaseDesc.fragmentFunction = lib.makeFunction(name: "fcrease")
            creaseDesc.colorAttachments[0].pixelFormat = pixelFormat
            creasePipelineState = try device.makeRenderPipelineState(descriptor: creaseDesc)
        } catch {
            NSLog("deviceterm: metal pipeline setup failed: \(error)")
        }
    }
}
