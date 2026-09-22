import Foundation

/// Minimal single-program MPEG-TS muxer: one video elementary stream, and
/// optionally the phone's own microphone beside it.
///
/// Why MPEG-TS and not a raw Annex-B stream: TS carries real PTS/PCR. A raw
/// elementary stream makes ffmpeg synthesise timestamps at a nominal frame rate,
/// which drifts against the sensor's true rate over a long take and pulls the
/// picture out of sync with a mic recorded separately in OBS.
///
/// The encoder runs with frame reordering off, so DTS == PTS and every PES
/// header carries PTS alone.
final class TSMuxer {

    enum Codec {
        case h264, hevc
        /// ISO/IEC 13818-1 stream_type.
        var streamType: UInt8 { self == .h264 ? 0x1B : 0x24 }
    }

    private let pmtPID: UInt16 = 0x1000
    private let videoPID: UInt16 = 0x0100
    private let audioPID: UInt16 = 0x0101
    /// ISO/IEC 13818-1 stream_type for AAC carried in ADTS.
    private let audioStreamType: UInt8 = 0x0F

    private let codec: Codec
    /// Fixed for the life of the muxer. A PMT that promises an elementary stream
    /// which never delivers leaves a demuxer waiting on it, so audio is advertised
    /// only when there is a microphone to feed it -- and a muxer is built fresh on
    /// every reconnect anyway, so this never has to change mid-stream.
    private let hasAudio: Bool
    private var patCC: UInt8 = 0
    private var pmtCC: UInt8 = 0
    private var videoCC: UInt8 = 0
    private var audioCC: UInt8 = 0
    private var framesSincePSI = Int.max

    /// PTS runs this far ahead of PCR so a decoder always holds a little buffer.
    /// Every tick here is latency you feel, so it is kept to about a frame and a
    /// half at 30 fps -- enough to keep PTS ahead of PCR, no more.
    private let ptsLeadTicks: Int64 = 4_500  // 50 ms at 90 kHz
    /// Repeat PAT/PMT at least this often, so a client joining mid-stream can lock on.
    private let psiEveryFrames = 30

    init(codec: Codec, hasAudio: Bool = false) {
        self.codec = codec
        self.hasAudio = hasAudio
    }

    // MARK: - Public

    /// TS bytes for one access unit, with PAT/PMT inserted ahead of key frames.
    func mux(accessUnit: [UInt8], pts90k: Int64, keyframe: Bool) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(accessUnit.count + accessUnit.count / 180 * 8 + 376)

        if keyframe || framesSincePSI >= psiEveryFrames {
            out += psiPacket(pid: 0x0000, cc: &patCC, section: patSection())
            out += psiPacket(pid: pmtPID, cc: &pmtCC, section: pmtSection())
            framesSincePSI = 0
        }
        framesSincePSI += 1

        var pes = pesHeader(streamID: 0xE0, pts: pts90k + ptsLeadTicks, payloadCount: nil)
        pes += accessUnit
        out += packetize(pes: pes, pid: videoPID, cc: &videoCC, pcr: pts90k, randomAccess: keyframe)
        return Data(out)
    }

    /// TS bytes for one ADTS AAC frame, on the same 90 kHz clock as the video.
    ///
    /// No PCR and no random-access flag: the video stream owns the clock, and a
    /// second stream setting PCR would fight it. Empty when the muxer was built
    /// without audio, so a caller never has to check.
    func mux(adtsFrame: [UInt8], pts90k: Int64) -> Data {
        guard hasAudio else { return Data() }
        var pes = pesHeader(streamID: 0xC0, pts: pts90k + ptsLeadTicks, payloadCount: adtsFrame.count)
        pes += adtsFrame
        return Data(packetize(pes: pes, pid: audioPID, cc: &audioCC, pcr: nil, randomAccess: false))
    }

    // MARK: - Packetisation

    private func packetize(pes: [UInt8], pid: UInt16, cc: inout UInt8,
                           pcr: Int64?, randomAccess: Bool) -> [UInt8] {
        var out = [UInt8]()
        var offset = 0
        var first = true

        while offset < pes.count {
            // Only the first packet of an access unit carries PCR and the
            // random-access flag, so only it needs an adaptation field up front.
            let wantPCR = first ? pcr : nil
            let wantRandomAccess = first && randomAccess
            let afBodyMin = (wantPCR != nil || wantRandomAccess) ? (1 + (wantPCR != nil ? 6 : 0)) : 0
            let maxPayload = afBodyMin > 0 ? (183 - afBodyMin) : 184
            let take = min(pes.count - offset, maxPayload)

            out += emit(pid: pid, cc: &cc, start: first,
                        payload: pes[offset ..< offset + take],
                        pcr: wantPCR,
                        randomAccess: wantRandomAccess)
            offset += take
            first = false
        }
        return out
    }

    /// One 188-byte transport packet. `payload` must already fit alongside any
    /// adaptation field the flags require.
    private func emit(pid: UInt16, cc: inout UInt8, start: Bool,
                      payload: ArraySlice<UInt8>, pcr: Int64?, randomAccess: Bool) -> [UInt8] {
        let p = payload.count
        precondition(p <= 184, "payload overruns a TS packet")

        let wantPCR = pcr != nil
        let wantFlags = wantPCR || randomAccess
        let needAF = wantFlags || p < 184
        // adaptation_field_length counts the bytes after the length byte itself.
        let afLen = needAF ? (184 - p - 1) : 0
        if wantFlags { precondition(afLen >= 1 + (wantPCR ? 6 : 0), "no room for the adaptation field") }

        var pkt = [UInt8]()
        pkt.reserveCapacity(188)
        pkt.append(0x47)
        pkt.append(UInt8((start ? 0x40 : 0x00) | Int((pid >> 8) & 0x1F)))
        pkt.append(UInt8(pid & 0xFF))
        pkt.append(((needAF ? 0b11 : 0b01) << 4) | (cc & 0x0F))
        cc = (cc &+ 1) & 0x0F

        if needAF {
            pkt.append(UInt8(afLen))
            if afLen > 0 {
                var flags: UInt8 = 0
                if randomAccess { flags |= 0x40 }
                if wantPCR { flags |= 0x10 }
                pkt.append(flags)
                if let pcr { pkt += Self.encodePCR(pcr) }
                let stuffing = afLen - 1 - (wantPCR ? 6 : 0)
                if stuffing > 0 { pkt += [UInt8](repeating: 0xFF, count: stuffing) }
            }
        }
        pkt += payload
        precondition(pkt.count == 188, "malformed TS packet")
        return pkt
    }

    /// `payloadCount` nil leaves PES_packet_length at 0 -- unbounded, which the
    /// standard allows for video only. Audio has to state its length.
    private func pesHeader(streamID: UInt8, pts: Int64, payloadCount: Int?) -> [UInt8] {
        let headerDataLength = 5   // one PTS, no DTS
        var pes: [UInt8] = [0x00, 0x00, 0x01, streamID]
        let length = payloadCount.map { 3 + headerDataLength + $0 } ?? 0
        precondition(length <= 0xFFFF, "PES packet longer than its length field can hold")
        pes += [UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)]
        pes.append(0x84)     // marker '10', data_alignment_indicator = 1
        pes.append(0x80)     // PTS present, DTS absent
        pes.append(UInt8(headerDataLength))
        pes += Self.encodePTS(pts, guardBits: 0x02)
        return pes
    }

    // MARK: - Program-specific information

    private func psiPacket(pid: UInt16, cc: inout UInt8, section: [UInt8]) -> [UInt8] {
        var payload: [UInt8] = [0x00]  // pointer_field
        payload += section
        payload += [UInt8](repeating: 0xFF, count: 184 - payload.count)
        return emit(pid: pid, cc: &cc, start: true, payload: payload[...], pcr: nil, randomAccess: false)
    }

    private func patSection() -> [UInt8] {
        var s: [UInt8] = [0x00, 0xB0, 0x0D]  // table_id, ssi + section_length 13
        s += [0x00, 0x01]                    // transport_stream_id
        s += [0xC1, 0x00, 0x00]              // version 0 current, section 0 of 0
        s += [0x00, 0x01]                    // program_number 1
        s += pidBytes(pmtPID, prefix: 0xE0)
        return withCRC(s)
    }

    private func pmtSection() -> [UInt8] {
        // section_length counts every byte after it, the CRC included: 9 bytes of
        // fixed fields, 5 per elementary stream, 4 of CRC.
        let sectionLength = 9 + 5 * (hasAudio ? 2 : 1) + 4
        var s: [UInt8] = [0x02, 0xB0, UInt8(sectionLength)]
        s += [0x00, 0x01]                      // program_number 1
        s += [0xC1, 0x00, 0x00]
        s += pidBytes(videoPID, prefix: 0xE0)  // PCR_PID -- the video stream keeps the clock
        s += [0xF0, 0x00]                      // program_info_length 0
        s.append(codec.streamType)
        s += pidBytes(videoPID, prefix: 0xE0)  // elementary_PID
        s += [0xF0, 0x00]                      // ES_info_length 0
        if hasAudio {
            s.append(audioStreamType)
            s += pidBytes(audioPID, prefix: 0xE0)
            s += [0xF0, 0x00]
        }
        return withCRC(s)
    }

    private func pidBytes(_ pid: UInt16, prefix: UInt8) -> [UInt8] {
        [prefix | UInt8((pid >> 8) & 0x1F), UInt8(pid & 0xFF)]
    }

    private func withCRC(_ section: [UInt8]) -> [UInt8] {
        let crc = Self.crc32(section)
        return section + [UInt8((crc >> 24) & 0xFF), UInt8((crc >> 16) & 0xFF),
                          UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
    }

    // MARK: - Field encodings

    /// 33-bit 90 kHz value spread over 5 bytes with the mandatory marker bits.
    private static func encodePTS(_ pts: Int64, guardBits: UInt8) -> [UInt8] {
        let v = UInt64(max(0, pts)) & 0x1_FFFF_FFFF
        return [
            (guardBits << 4) | UInt8(((v >> 30) & 0x07) << 1) | 0x01,
            UInt8((v >> 22) & 0xFF),
            UInt8(((v >> 15) & 0x7F) << 1) | 0x01,
            UInt8((v >> 7) & 0xFF),
            UInt8((v & 0x7F) << 1) | 0x01,
        ]
    }

    /// 33-bit base at 90 kHz plus a 9-bit 27 MHz extension, which we leave at zero.
    private static func encodePCR(_ pcr90k: Int64) -> [UInt8] {
        let base = UInt64(max(0, pcr90k)) & 0x1_FFFF_FFFF
        return [
            UInt8((base >> 25) & 0xFF),
            UInt8((base >> 17) & 0xFF),
            UInt8((base >> 9) & 0xFF),
            UInt8((base >> 1) & 0xFF),
            UInt8((base & 0x01) << 7) | 0x7E,
            0x00,
        ]
    }

    /// CRC-32/MPEG-2: polynomial 0x04C11DB7, seed all ones, no reflection, no final xor.
    private static let crcTable: [UInt32] = (0..<256).map { i in
        var crc = UInt32(i) << 24
        for _ in 0..<8 { crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1 }
        return crc
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes { crc = (crc << 8) ^ crcTable[Int(((crc >> 24) ^ UInt32(b)) & 0xFF)] }
        return crc
    }
}
