import AVFoundation
import CoreMedia

/// AAC-LC encoder for the phone's own microphone, producing ADTS frames for the muxer.
///
/// This track is not meant to be listened to. It exists because it travels with
/// the picture: same capture session, same socket, same buffering on the way into
/// OBS. Whatever delay the video picks up before it is recorded, this audio picks
/// up too. Cross-correlated afterwards against the DJI mic -- which OBS records on
/// its own track, straight off the Mac -- it gives the exact video lag for that
/// take, with no face detection and no lip reading. See `docs/SYNC.md`.
///
/// 64 kb/s mono: it is a timing reference, and a smaller frame is one less thing
/// competing with 40 Mb/s of video for the socket.
final class AudioEncoder {

    /// Called on the queue the samples arrive on, with one ADTS frame and its time.
    var onFrame: ((_ adts: [UInt8], _ pts: CMTime) -> Void)?

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var encodedFormat: AVAudioFormat?
    private var pending: AVAudioPCMBuffer?

    private let bitrate = 64_000
    /// AAC-LC always codes 1024 samples per frame.
    private let samplesPerFrame: AVAudioFrameCount = 1024

    // MARK: - Lifecycle

    func stop() {
        converter = nil
        sourceFormat = nil
        encodedFormat = nil
        pending = nil
    }

    /// One microphone sample buffer in, zero or more ADTS frames out.
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard let pcm = Self.pcmBuffer(sampleBuffer) else { return }
        guard let converter = converter(for: pcm.format), let encodedFormat else { return }

        // The encoder wants exactly 1024 samples at a time and the capture hands
        // over whatever the hardware buffered, so samples are queued and drawn
        // down a frame at a time. The leftover waits for the next buffer.
        pending = Self.append(pcm, to: pending)
        let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        var framesOut = 0
        while let queued = pending, queued.frameLength >= samplesPerFrame {
            guard let slice = Self.take(samplesPerFrame, from: queued) else { break }
            pending = slice.rest

            let out = AVAudioCompressedBuffer(format: encodedFormat,
                                              packetCapacity: 1,
                                              maximumPacketSize: converter.maximumOutputPacketSize)
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if supplied { outStatus.pointee = .noDataNow; return nil }
                supplied = true
                outStatus.pointee = .haveData
                return slice.head
            }
            guard status == .haveData, out.byteLength > 0, error == nil else { continue }

            let payload = [UInt8](UnsafeBufferPointer(
                start: out.data.assumingMemoryBound(to: UInt8.self), count: Int(out.byteLength)))
            let adts = Self.adtsHeader(payloadBytes: payload.count,
                                       sampleRate: pcm.format.sampleRate,
                                       channels: Int(pcm.format.channelCount)) + payload

            // Each frame is one 1024-sample step past the buffer's own timestamp,
            // so a run of frames out of one buffer keeps the capture's spacing.
            let offset = CMTime(value: CMTimeValue(framesOut) * CMTimeValue(samplesPerFrame),
                                timescale: CMTimeScale(pcm.format.sampleRate))
            onFrame?(adts, CMTimeAdd(start, offset))
            framesOut += 1
        }
    }

    // MARK: - Converter

    private func converter(for source: AVAudioFormat) -> AVAudioConverter? {
        if let converter, sourceFormat == source { return converter }

        var out = AudioStreamBasicDescription(mSampleRate: source.sampleRate,
                                              mFormatID: kAudioFormatMPEG4AAC,
                                              mFormatFlags: 0, mBytesPerPacket: 0,
                                              mFramesPerPacket: samplesPerFrame,
                                              mBytesPerFrame: 0,
                                              mChannelsPerFrame: source.channelCount,
                                              mBitsPerChannel: 0, mReserved: 0)
        guard let encoded = AVAudioFormat(streamDescription: &out),
              let made = AVAudioConverter(from: source, to: encoded) else { return nil }
        made.bitRate = bitrate

        converter = made
        sourceFormat = source
        encodedFormat = encoded
        pending = nil
        return made
    }

    // MARK: - Buffer plumbing

    private static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }

    /// Queue `buffer` behind whatever is already waiting.
    private static func append(_ buffer: AVAudioPCMBuffer, to queued: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        guard let queued, queued.format == buffer.format else { return buffer }
        let total = queued.frameLength + buffer.frameLength
        guard let joined = AVAudioPCMBuffer(pcmFormat: queued.format, frameCapacity: total) else { return buffer }
        joined.frameLength = total
        copy(queued, into: joined, at: 0)
        copy(buffer, into: joined, at: queued.frameLength)
        return joined
    }

    /// The first `count` samples, and what is left behind them.
    private static func take(_ count: AVAudioFrameCount, from buffer: AVAudioPCMBuffer)
        -> (head: AVAudioPCMBuffer, rest: AVAudioPCMBuffer?)? {
        guard buffer.frameLength >= count,
              let head = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else { return nil }
        head.frameLength = count
        copy(buffer, into: head, at: 0, count: count)

        let remaining = buffer.frameLength - count
        guard remaining > 0,
              let rest = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: remaining) else {
            return (head, nil)
        }
        rest.frameLength = remaining
        copy(buffer, into: rest, at: 0, from: count, count: remaining)
        return (head, rest)
    }

    private static func copy(_ source: AVAudioPCMBuffer, into destination: AVAudioPCMBuffer,
                             at offset: AVAudioFrameCount, from start: AVAudioFrameCount = 0,
                             count: AVAudioFrameCount? = nil) {
        let frames = Int(count ?? source.frameLength)
        let stride = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        guard frames > 0, stride > 0 else { return }

        let src = UnsafeMutableAudioBufferListPointer(source.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        for buffer in 0 ..< min(src.count, dst.count) {
            guard let from = src[buffer].mData, let to = dst[buffer].mData else { continue }
            to.advanced(by: Int(offset) * stride)
              .copyMemory(from: from.advanced(by: Int(start) * stride), byteCount: frames * stride)
        }
    }

    // MARK: - ADTS

    /// The 7-byte header that makes a raw AAC frame self-describing, which is what
    /// stream_type 0x0F in the PMT promises the demuxer it will find.
    private static func adtsHeader(payloadBytes: Int, sampleRate: Double, channels: Int) -> [UInt8] {
        let rates: [Double] = [96000, 88200, 64000, 48000, 44100, 32000,
                               24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let index = rates.firstIndex(of: sampleRate) ?? 3    // 48 kHz, what the phone gives
        let frame = payloadBytes + 7
        let profile = 1                                       // AAC-LC
        // One field per line: folded into a single array literal, the mix of
        // shifts, masks and UInt8 conversions is more than the type checker
        // will resolve, and the build fails.
        let byte2 = UInt8((profile << 6) | (index << 2) | ((channels >> 2) & 0x01))
        let byte3 = UInt8(((channels & 0x03) << 6) | ((frame >> 11) & 0x03))
        let byte4 = UInt8((frame >> 3) & 0xFF)
        let byte5 = UInt8(((frame & 0x07) << 5) | 0x1F)       // + buffer fullness, high bits
        return [0xFF, 0xF1, byte2, byte3, byte4, byte5, 0xFC]  // sync word, MPEG-4, no CRC ... fullness, 1 block
    }
}
