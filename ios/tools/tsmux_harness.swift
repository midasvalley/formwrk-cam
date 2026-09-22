import Foundation

/// Test harness: reads an Annex-B elementary stream, splits it into access units
/// at each access unit delimiter, and muxes it with TSMuxer. Given a fourth
/// argument -- an ADTS AAC file -- it muxes that alongside, interleaved by
/// timestamp the way the app does.
///   tsmux_harness <in.264|in.hevc> <out.ts> <h264|hevc> [in.aac]
@main
struct Harness {
    static var hevc = false

    static func nals(_ d: [UInt8]) -> [(start: Int, header: Int)] {
        var out: [(Int, Int)] = []
        var i = 0
        while i + 3 < d.count {
            if d[i] == 0, d[i+1] == 0, d[i+2] == 1 { out.append((i, i+3)); i += 3 }
            else if i + 4 < d.count, d[i] == 0, d[i+1] == 0, d[i+2] == 0, d[i+3] == 1 { out.append((i, i+4)); i += 4 }
            else { i += 1 }
        }
        return out
    }

    static func type(_ d: [UInt8], _ h: Int) -> Int { hevc ? Int((d[h] >> 1) & 0x3F) : Int(d[h] & 0x1F) }

    static func isKey(_ au: [UInt8]) -> Bool {
        nals(au).contains { hevc ? (16...21).contains(type(au, $0.header)) : type(au, $0.header) == 5 }
    }

    /// Split an ADTS file into frames. The header carries its own frame length,
    /// which is the whole point of ADTS and what stream_type 0x0F promises.
    static func adtsFrames(_ d: [UInt8]) -> [[UInt8]] {
        var out: [[UInt8]] = []
        var i = 0
        while i + 7 <= d.count, d[i] == 0xFF, (d[i + 1] & 0xF0) == 0xF0 {
            let length = (Int(d[i + 3] & 0x03) << 11) | (Int(d[i + 4]) << 3) | (Int(d[i + 5]) >> 5)
            guard length >= 7, i + length <= d.count else { break }
            out.append(Array(d[i ..< i + length]))
            i += length
        }
        return out
    }

    static func main() throws {
        let args = CommandLine.arguments
        hevc = args.count > 3 && args[3] == "hevc"
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))

        let audType = hevc ? 35 : 9
        let starts = nals(bytes).filter { type(bytes, $0.header) == audType }.map { $0.start }
        let units = starts.enumerated().map { n, s in
            Array(bytes[s ..< (n + 1 < starts.count ? starts[n + 1] : bytes.count)])
        }

        let aac = args.count > 4
            ? adtsFrames([UInt8](try Data(contentsOf: URL(fileURLWithPath: args[4]))))
            : []
        // 1024 samples at 48 kHz, in 90 kHz ticks.
        let audioStep: Int64 = 1024 * 90_000 / 48_000

        let muxer = TSMuxer(codec: hevc ? .hevc : .h264, hasAudio: !aac.isEmpty)
        var out = Data()
        var nextAudio = 0
        for (n, au) in units.enumerated() {
            let pts = Int64(n) * 3000
            // Interleave: every audio frame whose time has come goes out before the
            // picture it belongs with, which is the order the app produces them in.
            while nextAudio < aac.count, Int64(nextAudio) * audioStep <= pts {
                out += muxer.mux(adtsFrame: aac[nextAudio], pts90k: Int64(nextAudio) * audioStep)
                nextAudio += 1
            }
            out += muxer.mux(accessUnit: au, pts90k: pts, keyframe: isKey(au))
        }
        try out.write(to: URL(fileURLWithPath: args[2]))

        FileHandle.standardError.write(
            "AUs \(units.count)  keyframes \(units.filter(isKey).count)  audio \(nextAudio)  packets \(out.count / 188)  remainder \(out.count % 188)\n"
                .data(using: .utf8)!)
    }
}
