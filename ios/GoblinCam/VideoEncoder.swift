import Foundation
import VideoToolbox
import CoreMedia

/// Hardware H.264/HEVC encoder producing Annex-B access units ready for the muxer.
///
/// Frame reordering is off: no B-frames means DTS == PTS, which keeps both the
/// muxer and the end-to-end latency simple.
final class VideoEncoder {

    struct Config {
        var codec: TSMuxer.Codec = .hevc
        var width: Int32 = 2160
        var height: Int32 = 3840
        var bitrate: Int = 40_000_000
        var frameRate: Int = 30
        var keyframeIntervalSeconds: Double = 1.0
    }

    /// Called on the encoder's own queue with one complete access unit.
    var onAccessUnit: ((_ annexB: [UInt8], _ pts: CMTime, _ keyframe: Bool) -> Void)?

    private var session: VTCompressionSession?
    private var config = Config()
    private let lock = NSLock()

    // MARK: - Lifecycle

    func start(_ config: Config) throws {
        stop()
        lock.lock(); self.config = config; lock.unlock()

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: config.width,
            height: config.height,
            codecType: config.codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
            // No encoder specification: on iOS, H.264 and HEVC are hardware-only regardless.
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session)

        guard status == noErr, let session else {
            throw NSError(domain: "GoblinCam.VideoEncoder", code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: "could not create the \(config.codec) encoder (OSStatus \(status))"])
        }
        self.session = session

        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ProfileLevel,
            config.codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, config.frameRate as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, config.keyframeIntervalSeconds as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval,
            Int(config.keyframeIntervalSeconds * Double(config.frameRate)) as CFNumber)
        applyBitrate(config.bitrate)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func stop() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }

    /// Change bitrate without tearing down the session, so the picture never drops.
    func setBitrate(_ bps: Int) {
        lock.lock(); config.bitrate = bps; lock.unlock()
        applyBitrate(bps)
    }

    // MARK: - Encoding

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool) {
        guard let session else { return }
        let properties: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
            : nil

        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil) { [weak self] status, _, sampleBuffer in
                guard status == noErr, let sampleBuffer, let self else { return }
                self.handle(sampleBuffer)
            }
    }

    private func handle(_ sampleBuffer: CMSampleBuffer) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let keyframe = Self.isKeyframe(sampleBuffer)
        var annexB = [UInt8]()

        // An access unit delimiter first; some demuxers lean on it for AU boundaries.
        annexB += config.codec == .hevc
            ? [0x00, 0x00, 0x00, 0x01, 0x46, 0x01, 0x50]
            : [0x00, 0x00, 0x00, 0x01, 0x09, 0xF0]

        // Parameter sets ride along with every key frame, so a client joining
        // mid-stream can decode from the first picture it sees.
        if keyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for set in Self.parameterSets(format, codec: config.codec) {
                annexB += [0x00, 0x00, 0x00, 0x01]
                annexB += set
            }
        }

        var lengthAtOffset = 0, totalLength = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset,
                                          totalLengthOut: &totalLength, dataPointerOut: &pointer) == noErr,
              let pointer else { return }

        // VideoToolbox hands back length-prefixed NAL units; Annex-B wants start codes.
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        var offset = 0
        while offset + 4 <= totalLength {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                       | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            offset += 4
            guard length > 0, offset + length <= totalLength else { break }
            annexB += [0x00, 0x00, 0x00, 0x01]
            annexB += UnsafeBufferPointer(start: bytes + offset, count: length)
            offset += length
        }

        onAccessUnit?(annexB, CMSampleBufferGetPresentationTimeStamp(sampleBuffer), keyframe)
    }

    // MARK: - Helpers

    private func applyBitrate(_ bps: Int) {
        set(kVTCompressionPropertyKey_AverageBitRate, bps as CFNumber)
        // Cap bursts at 1.5x over a one-second window so a spike cannot stall the socket.
        set(kVTCompressionPropertyKey_DataRateLimits, [bps / 8 * 3 / 2, 1] as CFArray)
    }

    private func set(_ key: CFString, _ value: CFTypeRef?) {
        guard let session, let value else { return }
        VTSessionSetProperty(session, key: key, value: value)
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }

    private static func parameterSets(_ format: CMFormatDescription, codec: TSMuxer.Codec) -> [[UInt8]] {
        var count = 0
        let probe = codec == .hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                                                                 parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        guard probe == noErr else { return [] }

        return (0..<count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = codec == .hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                     parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            return Array(UnsafeBufferPointer(start: pointer, count: size))
        }
    }
}
