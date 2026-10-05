import SwiftUI
import AVFoundation

struct ContentView: View {
    @ObservedObject var camera: CaptureController
    @State private var showControls = true

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()
            CameraPreview(session: camera.session, rotation: camera.rotation) { camera.focus(at: $0) }
                .ignoresSafeArea()

            VStack(spacing: 6) {
                statusBar
                if let warning = camera.effectsWarning {
                    Text(warning)
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.red.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            VStack {
                Spacer()
                if showControls { controls }
                Button(showControls ? "Hide controls" : "Controls") {
                    withAnimation(.easeOut(duration: 0.15)) { showControls.toggle() }
                }
                .font(.footnote.weight(.semibold))
                .padding(.vertical, 10)
            }
        }
    }

    // MARK: - Status

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(camera.stats.clients > 0 ? .green : (camera.stats.listening ? .yellow : .red))
                .frame(width: 8, height: 8)
            Text(connectionText).font(.caption.monospaced())
            Spacer()
            Text(String(format: "%.0f fps  %.1f Mb/s", camera.measuredFPS, camera.mbps))
                .font(.caption.monospaced())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
    }

    private var connectionText: String {
        guard camera.stats.listening else { return "not listening" }
        let clients = camera.stats.clients
        let sizeAndPort = "\(camera.outputSize) :\(camera.stats.port)"
        return clients > 0 ? "\(clients) connected  \(sizeAndPort)" : "waiting  \(sizeAndPort)"
    }

    // MARK: - Controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(camera.status).font(.caption).foregroundStyle(.secondary)

                if camera.lenses.count > 1 {
                    labelled("Lens") {
                        Picker("", selection: $camera.lensIndex) {
                            ForEach(Array(camera.lenses.enumerated()), id: \.offset) { index, device in
                                Text(Self.shortName(device)).tag(index)
                            }
                        }.pickerStyle(.segmented)
                    }
                }

                labelled("Size") {
                    Picker("", selection: $camera.resolution) {
                        ForEach(CaptureController.Resolution.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }

                labelled("Frame rate") {
                    Picker("", selection: $camera.frameRate) {
                        ForEach(camera.availableFrameRates, id: \.self) { Text("\($0)").tag($0) }
                    }.pickerStyle(.segmented)
                }

                labelled("Codec") {
                    Picker("", selection: $camera.codec) {
                        Text("HEVC").tag(TSMuxer.Codec.hevc)
                        Text("H.264").tag(TSMuxer.Codec.h264)
                    }.pickerStyle(.segmented)
                }

                labelled("Orientation  (fixed - never auto-rotates)") {
                    Picker("", selection: $camera.rotation) {
                        Text("Portrait").tag(90)
                        Text("Landscape").tag(0)
                        Text("Portrait ⟲").tag(270)
                        Text("Landscape ⟲").tag(180)
                    }.pickerStyle(.segmented)
                }

                slider("Bitrate", value: Binding(
                    get: { Double(camera.bitrateMbps) },
                    set: { camera.bitrateMbps = Int($0) }),
                    range: 5...120, step: 5, format: "\(camera.bitrateMbps) Mb/s")

                slider("Zoom", value: $camera.zoom, range: 1...max(camera.maxZoom, 1.1), step: 0.1,
                       format: String(format: "%.1fx", camera.zoom))

                Toggle("Stabilisation  (crops in)", isOn: $camera.stabilization).font(.caption)

                Divider().overlay(.white.opacity(0.2))

                Toggle("Lock focus", isOn: $camera.lockFocus).font(.caption)
                if camera.lockFocus {
                    slider("Distance", value: $camera.lensPosition, range: 0...1, step: 0.01,
                           format: String(format: "%.2f", camera.lensPosition))
                }

                Toggle("Manual exposure", isOn: $camera.manualExposure).font(.caption)
                if camera.manualExposure {
                    slider("ISO", value: $camera.iso, range: camera.isoRange, step: 10,
                           format: String(format: "%.0f", camera.iso))
                    slider("Shutter", value: $camera.shutterDenominator, range: 24...2000, step: 1,
                           format: "1/\(Int(camera.shutterDenominator))")
                } else {
                    Toggle("Lock exposure", isOn: $camera.lockExposure).font(.caption)
                    if !camera.lockExposure {
                        slider("Exposure bias", value: $camera.exposureBias, range: -3...3, step: 0.1,
                               format: String(format: "%+.1f EV", camera.exposureBias))
                    }
                }

                Toggle("Manual white balance", isOn: $camera.manualWhiteBalance).font(.caption)
                if camera.manualWhiteBalance {
                    slider("Temperature", value: $camera.temperature, range: 2500...8000, step: 50,
                           format: "\(Int(camera.temperature))K")
                    slider("Tint", value: $camera.tint, range: -50...50, step: 1,
                           format: String(format: "%+.0f", camera.tint))
                } else {
                    Toggle("Lock white balance", isOn: $camera.lockWhiteBalance).font(.caption)
                }
            }
            .padding(16)
        }
        .frame(maxHeight: 380)
        .background(.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal, 10)
        .foregroundStyle(.white)
    }

    // MARK: - Building blocks

    private func labelled<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        step: Double, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text(format).font(.caption2.monospaced())
            }
            Slider(value: value, in: range, step: step)
        }
    }

    private static func shortName(_ device: AVCaptureDevice) -> String {
        let side = device.position == .front ? "Front" : ""
        switch device.deviceType {
        case .builtInUltraWideCamera: return side.isEmpty ? "0.5x" : "\(side) UW"
        case .builtInTelephotoCamera: return side.isEmpty ? "Tele" : "\(side) Tele"
        default: return side.isEmpty ? "1x" : side
        }
    }
}
