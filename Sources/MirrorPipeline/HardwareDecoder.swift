// SPDX-License-Identifier: GPL-3.0-or-later

import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Decodes HEVC access units to IOSurface-backed BGRA `CVPixelBuffer`s through a
/// `VTDecompressionSession`, built from the VPS/SPS/PPS parameter sets.
///
/// `decode` passes no asynchronous flag, so decode and its `onImage` callback
/// complete synchronously: the callback runs on the caller's thread before
/// `decode` returns. VT recycles its pool, so a consumer that keeps the
/// underlying surface must hold the buffer until it has a newer one.
///
/// `@unchecked Sendable`: the decoder is created and used entirely on the
/// pipeline's single receive task (the synchronous decode callback runs there
/// too), so its mutable state is never touched concurrently.
final class HardwareDecoder: @unchecked Sendable {
    enum DecoderError: Error, Sendable {
        case formatDescription(OSStatus)
        case sessionCreate(OSStatus)
        case blockBuffer(OSStatus)
        case sampleBuffer(OSStatus)
    }

    /// Fired for each decoded frame, synchronously within `decode` (on the
    /// caller's thread, the pipeline's detached receive task).
    var onImage: ((CVPixelBuffer) -> Void)?
    /// Fired with a non-`noErr` status whenever a submitted frame fails to
    /// decode, synchronously or in the output callback. A dropped frame breaks the
    /// reference chain, so surfacing the count separates a lossy stream from a
    /// clean one.
    var onDecodeError: ((OSStatus) -> Void)?

    private let formatDescription: CMVideoFormatDescription
    private var session: VTDecompressionSession?
    private var sampleIndex: Int64 = 0

    /// Whether VideoToolbox selected the hardware decoder, or nil if the property
    /// is unavailable. Lets a diagnostic confirm the decode path.
    var usingHardwareDecoder: Bool? {
        guard let session else { return nil }
        // `Unmanaged` rather than a bare `CFTypeRef?`: the property is vended
        // +1 ("the caller must release the retrieved property value"), and the
        // out-parameter is an untyped `void *`, so an unmanaged slot both makes
        // the ownership transfer explicit and keeps ARC out of a raw write.
        var value: Unmanaged<CFTypeRef>?
        let status = VTSessionCopyProperty(
            session,
            key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault,
            valueOut: &value
        )
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as? Bool
    }

    init(vps: [UInt8], sps: [UInt8], pps: [UInt8]) throws {
        self.formatDescription = try Self.makeFormatDescription(vps: vps, sps: sps, pps: pps)
        try startSession()
    }

    deinit {
        if let session { VTDecompressionSessionInvalidate(session) }
    }

    static func makeFormatDescription(vps: [UInt8], sps: [UInt8], pps: [UInt8]) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status: OSStatus = vps.withUnsafeBufferPointer { vpsBuffer in
            sps.withUnsafeBufferPointer { spsBuffer in
                pps.withUnsafeBufferPointer { ppsBuffer in
                    guard let vpsBase = vpsBuffer.baseAddress,
                        let spsBase = spsBuffer.baseAddress,
                        let ppsBase = ppsBuffer.baseAddress else { return OSStatus(-1) }
                    let pointers = [vpsBase, spsBase, ppsBase]
                    let sizes = [vps.count, sps.count, pps.count]
                    return pointers.withUnsafeBufferPointer { pointerBuffer in
                        sizes.withUnsafeBufferPointer { sizeBuffer in
                            guard let pointerBase = pointerBuffer.baseAddress,
                                let sizeBase = sizeBuffer.baseAddress else { return OSStatus(-1) }
                            return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 3,
                                parameterSetPointers: pointerBase,
                                parameterSetSizes: sizeBase,
                                nalUnitHeaderLength: 4,
                                extensions: nil,
                                formatDescriptionOut: &description
                            )
                        }
                    }
                }
            }
        }
        guard status == noErr, let description else { throw DecoderError.formatDescription(status) }
        return description
    }

    /// Concatenate NAL units as 4-byte length-prefixed (AVCC) bytes.
    static func avcc(from nals: [[UInt8]]) -> Data {
        var out = Data()
        for nal in nals where !nal.isEmpty {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(contentsOf: nal)
        }
        return out
    }

    /// Build a fully-timed sample buffer for one access unit: AVCC data in a
    /// CoreMedia block buffer, one sample with monotonic 60 Hz PTS/DTS/duration,
    /// and the `NotSync` attachment on non-keyframes. Returns nil for an empty
    /// access unit.
    static func makeSampleBuffer(
        accessUnit nals: [[UInt8]],
        formatDescription: CMVideoFormatDescription,
        index: Int64,
        isKeyframe: Bool
    ) throws -> CMSampleBuffer? {
        let avcc = avcc(from: nals)
        guard !avcc.isEmpty else { return nil }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else { throw DecoderError.blockBuffer(status) }
        status = avcc.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return OSStatus(-1) }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avcc.count
            )
        }
        guard status == noErr else { throw DecoderError.blockBuffer(status) }

        let timescale: CMTimeScale = 60
        let presentation = CMTime(value: index, timescale: timescale)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: presentation,
            decodeTimeStamp: presentation
        )
        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw DecoderError.sampleBuffer(status) }
        if !isKeyframe { markNotSync(sampleBuffer) }
        return sampleBuffer
    }

    /// Set the `NotSync` per-sample attachment so decoders don't treat a
    /// non-keyframe as a resync point.
    private static func markNotSync(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
            CFArrayGetCount(attachments) > 0 else { return }
        let raw = CFArrayGetValueAtIndex(attachments, 0)
        let dictionary = unsafeBitCast(raw, to: CFMutableDictionary.self)
        CFDictionarySetValue(
            dictionary,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
        )
    }

    private func startSession() throws {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: nil,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else { throw DecoderError.sessionCreate(status) }
        self.session = session
    }

    /// Decode one access unit (the NAL units of a single coded picture). A
    /// successful frame surfaces synchronously through `onImage` before this
    /// returns.
    ///
    /// Synchronous, in-order decode (no flags): asynchronous/real-time decode
    /// lets VideoToolbox reorder or drop frames under load, so an inter-frame
    /// decodes against the wrong reference and shows corruption. A phone-sized
    /// HEVC frame decodes in a few ms, well inside the 60fps budget, off the main
    /// thread.
    func decode(accessUnit nals: [[UInt8]], isKeyframe: Bool) throws {
        guard let session else { return }
        let index = sampleIndex
        guard let sampleBuffer = try Self.makeSampleBuffer(
            accessUnit: nals, formatDescription: formatDescription, index: index, isKeyframe: isKeyframe
        ) else { return }
        sampleIndex += 1

        let flags: VTDecodeFrameFlags = []
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer, flags: flags, infoFlagsOut: nil
        ) { [weak self] status, _, imageBuffer, _, _ in
            guard status == noErr, let imageBuffer else {
                self?.onDecodeError?(status)
                return
            }
            self?.onImage?(imageBuffer)
        }
        if status != noErr { onDecodeError?(status) }
    }
}
