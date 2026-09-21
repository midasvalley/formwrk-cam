import Foundation

/// Test harness: reads an Annex-B elementary stream, splits it into access units
/// at each access unit delimiter, and muxes it with TSMuxer.
///   tsmux_harness <in.264|in.hevc> <out.ts> <h264|hevc>
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

    static func main() throws {
        let args = CommandLine.arguments
        hevc = args.count > 3 && args[3] == "hevc"
        let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: args[1])))

        let audType = hevc ? 35 : 9
        let starts = nals(bytes).filter { type(bytes, $0.header) == audType }.map { $0.start }
        let units = starts.enumerated().map { n, s in
            Array(bytes[s ..< (n + 1 < starts.count ? starts[n + 1] : bytes.count)])
        }

        let muxer = TSMuxer(codec: hevc ? .hevc : .h264)
        var out = Data()
        for (n, au) in units.enumerated() {
            out += muxer.mux(accessUnit: au, pts90k: Int64(n) * 3000, keyframe: isKey(au))
        }
        try out.write(to: URL(fileURLWithPath: args[2]))

        FileHandle.standardError.write(
            "AUs \(units.count)  keyframes \(units.filter(isKey).count)  packets \(out.count / 188)  remainder \(out.count % 188)\n"
                .data(using: .utf8)!)
    }
}
