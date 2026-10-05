import Foundation
import AVFoundation
import CoreMedia
import UIKit

/// Owns the capture session and drives encode -> mux -> serve.
///
/// The session runs on `.inputPriority` so we choose `activeFormat` ourselves
/// rather than letting a preset pick for us; that is the only way to pin a true
/// 3840x2160 sensor format instead of whatever a preset decides to hand back.
final class CaptureController: NSObject, ObservableObject {

    enum Resolution: String, CaseIterable, Identifiable {
        case uhd4K = "4K", hd1080 = "1080p"
        var id: String { rawValue }
        var dimensions: (width: Int32, height: Int32) {
            self == .uhd4K ? (3840, 2160) : (1920, 1080)
        }
    }

    // MARK: - Published state

    @Published private(set) var lenses: [AVCaptureDevice] = []
    @Published private(set) var status = "starting"
    @Published private(set) var stats = StreamServer.Stats()
    @Published private(set) var outputSize = "—"
    @Published private(set) var measuredFPS: Double = 0
    @Published private(set) var mbps: Double = 0
    /// Effects the OS applies that no app can switch off. Naming them beats
    /// letting them quietly soften the picture.
    @Published private(set) var effectsWarning: String?
    private var formatSize: (width: Int32, height: Int32) = (0, 0)

    @Published var lensIndex = 0 { didSet { reconfigureSession() } }
    @Published var resolution: Resolution = .uhd4K { didSet { reconfigureSession() } }
    @Published var frameRate = 30 { didSet { reconfigureSession() } }
    @Published var codec: TSMuxer.Codec = .hevc { didSet { restartEncoder() } }
    @Published var bitrateMbps = 40 { didSet { encoder.setBitrate(bitrateMbps * 1_000_000) } }
    // Landscape, because that is what the episodes are shot in. Shorts flip to
    // portrait with one command from the Mac.
    @Published var rotation = 0 { didSet { applyRotation() } }

    @Published var zoom: Double = 1 { didSet { applyDevice() } }
    @Published var stabilization = false { didSet { applyRotation() } }

    @Published var lockFocus = false { didSet { applyDevice() } }
    @Published var lensPosition: Double = 0.5 { didSet { applyDevice() } }
    @Published var lockExposure = false { didSet { applyDevice() } }
    @Published var exposureBias: Double = 0 { didSet { applyDevice() } }
    @Published var manualExposure = false { didSet { applyDevice() } }
    @Published var iso: Double = 200 { didSet { applyDevice() } }
    @Published var shutterDenominator: Double = 60 { didSet { applyDevice() } }
    @Published var lockWhiteBalance = false { didSet { applyDevice() } }
    @Published var manualWhiteBalance = false { didSet { applyDevice() } }
    @Published var temperature: Double = 5200 { didSet { applyDevice() } }
    @Published var tint: Double = 0 { didSet { applyDevice() } }

    /// Limits for the active format, so the UI can bound its sliders honestly.
    @Published private(set) var isoRange: ClosedRange<Double> = 50...800
    @Published private(set) var maxZoom: Double = 4
    @Published private(set) var availableFrameRates: [Int] = [30]

    let session = AVCaptureSession()

    // MARK: - Private

    private let encoder = VideoEncoder()
    private let audioEncoder = AudioEncoder()
    private let server = StreamServer()
    private let control = ControlServer()
    private var muxer = TSMuxer(codec: .hevc)
    private let sessionQueue = DispatchQueue(label: "formwrkcam.session")
    private let outputQueue = DispatchQueue(label: "formwrkcam.output")
    /// Video and audio are encoded on different queues but share one muxer and one
    /// socket, and a transport stream is a single ordered sequence with a
    /// continuity counter per PID. Everything that touches the muxer goes through
    /// here, in the order it arrives.
    private let muxQueue = DispatchQueue(label: "formwrkcam.mux")
    private let output = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "formwrkcam.audio")

    private var device: AVCaptureDevice?
    private var input: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private var encoderRunning = false
    private var forceKeyframe = false
    private var ptsBase: CMTime?
    private var frameTimestamps: [CFTimeInterval] = []
    private var lastBytesSent = 0
    private var statsTimer: Timer?

    private let port: UInt16 = 9000
    private let controlPort: UInt16 = 9001

    // MARK: - Lifecycle

    override init() {
        super.init()
        encoder.onAccessUnit = { [weak self] annexB, pts, keyframe in
            self?.handleAccessUnit(annexB, pts: pts, keyframe: keyframe)
        }
        audioEncoder.onFrame = { [weak self] adts, pts in
            self?.handleAudioFrame(adts, pts: pts)
        }
        server.onNeedsKeyframe = { [weak self] in self?.forceKeyframe = true }
        server.onClientCountChanged = { [weak self] count in
            guard let self else { return }
            self.outputQueue.async { count > 0 ? self.startEncoder() : self.stopEncoder() }
        }
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.status = "camera access denied" }
                return
            }
            // The microphone is the sync reference, not content: ask for it, carry
            // on either way, and configure the session once the answer is in so the
            // input can go in with everything else.
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                self.sessionQueue.async { self.configureSession() }
            }
        }
        server.start(port: port)
        control.onCommand = { [weak self] line in self?.handle(command: line) ?? "error" }
        control.start(port: controlPort)
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.effectsWarning = Self.uncontrollableEffects()
            let snapshot = self.server.snapshot()
            // Two samples a second, so the delta is a half-second window.
            self.mbps = Double(snapshot.bytesSent - self.lastBytesSent) * 8 / 0.5 / 1_000_000
            self.lastBytesSent = snapshot.bytesSent
            self.stats = snapshot
        }
    }

    /// Coming back from a locked screen or a trip to the home screen. iOS stops the
    /// session while the app is away and the interface change can take the listeners
    /// with it, which used to mean force-quitting the app to get the feed back.
    /// Every call here is idempotent, so running it on each return is safe.
    func resume() {
        UIApplication.shared.isIdleTimerDisabled = true
        server.start(port: port)
        control.start(port: controlPort)
        sessionQueue.async {
            guard !self.session.isRunning else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        UIApplication.shared.isIdleTimerDisabled = false
        statsTimer?.invalidate()
        control.stop()
        server.stop()
        outputQueue.async { self.stopEncoder() }
        sessionQueue.async { self.session.stopRunning() }
    }

    /// One control line from the Mac. Orientation is the only thing worth driving
    /// remotely: everything else is a look you set once and leave alone.
    private func handle(command: String) -> String {
        let parts = command.split(separator: " ").map(String.init)
        switch parts.first {
        case "rotate":
            guard parts.count == 2, let angle = Int(parts[1]), [0, 90, 180, 270].contains(angle) else {
                return "error rotate needs 0, 90, 180 or 270"
            }
            DispatchQueue.main.async { self.rotation = angle }
            return "ok \(angle)"
        case "lock":
            // Exposure and white balance only: those are what drift mid-take. Focus
            // is left alone, because a locked lens that lands soft cannot be nudged
            // back without walking over and reframing the shot.
            DispatchQueue.main.async {
                self.manualExposure = false
                self.manualWhiteBalance = false
                self.lockExposure = true
                self.lockWhiteBalance = true
            }
            return "ok locked"
        case "auto":
            DispatchQueue.main.async {
                self.manualExposure = false
                self.manualWhiteBalance = false
                self.lockExposure = false
                self.lockWhiteBalance = false
            }
            return "ok auto"
        case "set":
            // One or more pairs: `set iso 200 shutter 60 wb on focus 0.7` is one look,
            // validated whole and applied in one pass, never half of it.
            let pairs = Array(parts.dropFirst())
            guard !pairs.isEmpty, pairs.count % 2 == 0 else { return "error set needs key value pairs" }
            var assignments: [() -> Void] = []
            for i in stride(from: 0, to: pairs.count, by: 2) {
                switch setting(pairs[i], value: pairs[i + 1]) {
                case .failure(let message): return "error \(message)"
                case .success(let assign): assignments.append(assign)
                }
            }
            DispatchQueue.main.async { assignments.forEach { $0() } }
            return "ok " + pairs.joined(separator: " ")
        case "state":
            return "rotation=\(rotation) size=\(outputSize) fps=\(frameRate) clients=\(stats.clients) "
                + "zoom=\(String(format: "%.1f", zoom)) exposure=\(exposureSummary) wb=\(whiteBalanceSummary) "
                + "focus=\(lockFocus ? String(format: "locked %.2f", lensPosition) : "auto") "
                + "| device \(deviceReadout())"
        default:
            return "error unknown command"
        }
    }

    /// One `key value` from the Mac, parsed into the assignment it stands for. Each
    /// key drives the same published property the on-screen control does, so the
    /// phone's UI stays in step. Nothing is assigned here: `set` validates every
    /// pair first, then runs them together on the main queue.
    private func setting(_ key: String, value: String) -> Result<() -> Void, SettingError> {
        func number(_ assign: @escaping (Double) -> Void) -> Result<() -> Void, SettingError> {
            guard let parsed = Double(value) else { return .failure(SettingError("\(key) needs a number")) }
            return .success { assign(parsed) }
        }
        func flag(_ assign: @escaping (Bool) -> Void) -> Result<() -> Void, SettingError> {
            let on = ["on", "true", "1"].contains(value.lowercased())
            guard on || ["off", "false", "0"].contains(value.lowercased()) else {
                return .failure(SettingError("\(key) needs on or off"))
            }
            return .success { assign(on) }
        }

        switch key {
        case "zoom": return number { self.zoom = $0 }
        case "bias": return number { self.exposureBias = $0 }
        // Asking for a number is asking for manual control of the thing it belongs to.
        case "iso": return number { self.manualExposure = true; self.iso = $0 }
        case "shutter": return number { self.manualExposure = true; self.shutterDenominator = $0 }
        case "temp": return number { self.manualWhiteBalance = true; self.temperature = $0 }
        case "tint": return number { self.manualWhiteBalance = true; self.tint = $0 }
        case "focus": return number { self.lockFocus = true; self.lensPosition = $0 }
        case "bitrate": return number { self.bitrateMbps = Int($0) }
        case "exposure": return flag { self.manualExposure = false; self.lockExposure = $0 }
        case "wb": return flag { self.manualWhiteBalance = false; self.lockWhiteBalance = $0 }
        case "focuslock": return flag { self.lockFocus = $0 }
        default:
            return .failure(SettingError("unknown key \(key)"))
        }
    }

    struct SettingError: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// What the camera is actually doing, read off the device rather than off the
    /// settings we asked for. The first half of `state` is the request; this is the
    /// answer, so a setting that never landed shows up as a mismatch instead of an `ok`.
    /// `queue=stuck` means the session queue did not answer: settings will not apply.
    private func deviceReadout() -> String {
        let answered = DispatchSemaphore(value: 0)
        sessionQueue.async { answered.signal() }
        let queue = answered.wait(timeout: .now() + 0.5) == .success ? "ok" : "stuck"
        guard let device else { return "none queue=\(queue)" }

        let seconds = CMTimeGetSeconds(device.exposureDuration)
        let shutter = seconds > 0 ? "1/\(Int((1 / seconds).rounded()))" : "?"
        let exposure: String
        switch device.exposureMode {
        case .custom: exposure = "custom"
        case .locked: exposure = "locked"
        default: exposure = "auto"
        }
        let wb = device.whiteBalanceMode == .locked ? "locked" : "auto"
        let focus = device.focusMode == .locked ? "locked" : "auto"
        return "exposure=\(exposure) iso=\(Int(device.iso.rounded())) \(shutter) wb=\(wb) "
            + "focus=\(focus) \(String(format: "%.2f", device.lensPosition)) queue=\(queue)"
    }

    private var exposureSummary: String {
        if manualExposure { return "manual iso=\(Int(iso)) 1/\(Int(shutterDenominator))" }
        return lockExposure ? "locked" : String(format: "auto %+.1fEV", exposureBias)
    }

    private var whiteBalanceSummary: String {
        if manualWhiteBalance { return "manual \(Int(temperature))K tint=\(Int(tint))" }
        return lockWhiteBalance ? "locked" : "auto"
    }

    // MARK: - Session

    private func configureSession() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .unspecified)
        // Order them the way you would reach for them, so index 0 is the main
        // camera rather than whatever the discovery session happened to list first.
        let rank: (AVCaptureDevice) -> Int = { device in
            if device.position == .front { return 3 }
            switch device.deviceType {
            case .builtInWideAngleCamera: return 0
            case .builtInUltraWideCamera: return 1
            default: return 2
            }
        }
        let found = discovery.devices.sorted { rank($0) < rank($1) }
        DispatchQueue.main.async { self.lenses = found }
        guard !found.isEmpty else {
            DispatchQueue.main.async { self.status = "no camera" }
            return
        }

        // Center Stage is what makes Continuity Camera start at some arbitrary zoom
        // and drift while you talk. Take control of it and switch it off for good.
        // `.app` scopes the choice to us, so nothing else on the phone changes.
        AVCaptureDevice.centerStageControlMode = .app
        AVCaptureDevice.isCenterStageEnabled = false

        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        addMicrophone()
        session.commitConfiguration()

        applyLens(found[min(lensIndex, found.count - 1)])
        session.startRunning()
    }

    /// The phone's microphone, for the sync reference only -- see AudioEncoder.
    /// A refusal is not a failure: the stream carries video alone and the PMT
    /// never mentions audio, which is exactly how it behaved before this existed.
    private func addMicrophone() {
        guard audioInput == nil, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
              let microphone = AVCaptureDevice.default(for: .audio),
              let mic = try? AVCaptureDeviceInput(device: microphone),
              session.canAddInput(mic) else { return }
        session.addInput(mic)
        audioInput = mic
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
    }

    private func reconfigureSession() {
        sessionQueue.async {
            guard self.lensIndex < self.lenses.count else { return }
            self.applyLens(self.lenses[self.lensIndex])
            self.outputQueue.async { self.restartEncoderIfRunning() }
        }
    }

    private func applyLens(_ newDevice: AVCaptureDevice) {
        session.beginConfiguration()
        defer { session.commitConfiguration(); applyRotation(); applyDevice() }

        if let input { session.removeInput(input) }
        guard let newInput = try? AVCaptureDeviceInput(device: newDevice), session.canAddInput(newInput) else {
            DispatchQueue.main.async { self.status = "cannot open \(newDevice.localizedName)" }
            return
        }
        session.addInput(newInput)
        input = newInput
        device = newDevice

        let (width, height) = resolution.dimensions
        guard let format = Self.bestFormat(for: newDevice, width: width, height: height, fps: frameRate)
                ?? Self.bestFormat(for: newDevice, width: width, height: height, fps: 30) else {
            DispatchQueue.main.async { self.status = "\(self.resolution.rawValue) unavailable on this lens" }
            return
        }

        // Every one of these setters throws an Objective-C exception when the
        // active format does not support it, and Swift cannot catch those: it is
        // an instant abort. So each one is asked before it is told.
        guard (try? newDevice.lockForConfiguration()) != nil else { return }
        newDevice.activeFormat = format
        newDevice.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        newDevice.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        if newDevice.isLowLightBoostSupported {
            newDevice.automaticallyEnablesLowLightBoostWhenAvailable = false
        }
        // Auto HDR re-grades the picture mid-take. A take should look the way it
        // looked when you framed it.
        if format.isVideoHDRSupported {
            newDevice.automaticallyAdjustsVideoHDREnabled = false
            newDevice.isVideoHDREnabled = false
        }
        if format.supportedColorSpaces.contains(.sRGB) { newDevice.activeColorSpace = .sRGB }
        // Always open at a known zoom, so it never starts somewhere you did not put it.
        newDevice.videoZoomFactor = min(max(zoom, newDevice.minAvailableVideoZoomFactor),
                                        newDevice.maxAvailableVideoZoomFactor)
        newDevice.unlockForConfiguration()

        let rates = Set(format.videoSupportedFrameRateRanges.flatMap { range in
            [24, 25, 30, 48, 50, 60, 120].filter {
                Double($0) >= range.minFrameRate && Double($0) <= range.maxFrameRate
            }
        }).sorted()
        let isoLimits = Double(format.minISO)...Double(format.maxISO)
        let zoomLimit = min(Double(format.videoMaxZoomFactor), 8)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

        DispatchQueue.main.async {
            self.availableFrameRates = rates.isEmpty ? [30] : rates
            self.isoRange = isoLimits
            self.maxZoom = zoomLimit
            self.status = newDevice.localizedName
            self.formatSize = (dimensions.width, dimensions.height)
            self.refreshOutputSize()
        }
    }

    /// Prefer a native 8-bit format at the exact size: 10-bit HDR formats would
    /// need a Main10 encoder and an HLG-aware receiver, which OBS is not by default.
    private static func bestFormat(for device: AVCaptureDevice, width: Int32, height: Int32, fps: Int) -> AVCaptureDevice.Format? {
        let eightBit: Set<FourCharCode> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                           kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        return device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width == width, dimensions.height == height else { return false }
            guard eightBit.contains(CMFormatDescriptionGetMediaSubType(format.formatDescription)) else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                Double(fps) >= $0.minFrameRate && Double(fps) <= $0.maxFrameRate
            }
        }
        .sorted { a, b in
            if a.isVideoBinned != b.isVideoBinned { return !a.isVideoBinned }
            return a.videoFieldOfView > b.videoFieldOfView
        }
        .first
    }

    private func applyRotation() {
        sessionQueue.async {
            guard let connection = self.output.connection(with: .video) else { return }
            let angle = CGFloat(self.rotation)
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            let mode: AVCaptureVideoStabilizationMode = self.stabilization ? .standard : .off
            if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = mode }
            DispatchQueue.main.async { self.refreshOutputSize() }
            self.outputQueue.async { self.restartEncoderIfRunning() }
        }
    }

    /// Center Stage we own outright. These four are read-only to every app, so
    /// all we can do is say which are on and where to turn them off.
    private static func uncontrollableEffects() -> String? {
        var on: [String] = []
        if AVCaptureDevice.isPortraitEffectEnabled { on.append("Portrait") }
        if AVCaptureDevice.isStudioLightEnabled { on.append("Studio Light") }
        if AVCaptureDevice.reactionEffectsEnabled { on.append("Reactions") }
        if #available(iOS 18.0, *), AVCaptureDevice.isBackgroundReplacementEnabled {
            on.append("Background")
        }
        guard !on.isEmpty else { return nil }
        return "\(on.joined(separator: ", ")) on - turn off in Control Center > Video Effects"
    }

    /// Portrait swaps the sensor's own dimensions round; landscape leaves them.
    private func refreshOutputSize() {
        guard formatSize.width > 0 else { return }
        outputSize = rotation % 180 == 0
            ? "\(formatSize.width)x\(formatSize.height)"
            : "\(formatSize.height)x\(formatSize.width)"
    }

    private func applyDevice() {
        sessionQueue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }

            device.videoZoomFactor = min(max(self.zoom, device.minAvailableVideoZoomFactor),
                                         device.maxAvailableVideoZoomFactor)

            if self.lockFocus {
                if device.isFocusModeSupported(.locked) {
                    device.setFocusModeLocked(lensPosition: Float(self.lensPosition))
                }
            } else if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }

            if self.manualExposure, device.isExposureModeSupported(.custom) {
                let duration = CMTime(seconds: 1 / max(self.shutterDenominator, 1), preferredTimescale: 1_000_000)
                let clampedDuration = CMTimeMinimum(CMTimeMaximum(duration, device.activeFormat.minExposureDuration),
                                                    device.activeFormat.maxExposureDuration)
                let clampedISO = Float(min(max(self.iso, Double(device.activeFormat.minISO)), Double(device.activeFormat.maxISO)))
                device.setExposureModeCustom(duration: clampedDuration, iso: clampedISO)
            } else if self.lockExposure, device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            } else if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
                let bias = Float(min(max(self.exposureBias, Double(device.minExposureTargetBias)),
                                     Double(device.maxExposureTargetBias)))
                device.setExposureTargetBias(bias)
            }

            if self.manualWhiteBalance, device.isWhiteBalanceModeSupported(.locked) {
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(
                    temperature: Float(self.temperature), tint: Float(self.tint))
                var gains = device.deviceWhiteBalanceGains(for: values)
                let maxGain = device.maxWhiteBalanceGain
                gains.redGain = min(max(1, gains.redGain), maxGain)
                gains.greenGain = min(max(1, gains.greenGain), maxGain)
                gains.blueGain = min(max(1, gains.blueGain), maxGain)
                device.setWhiteBalanceModeLocked(with: gains)
            } else if self.lockWhiteBalance, device.isWhiteBalanceModeSupported(.locked) {
                device.whiteBalanceMode = .locked
            } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
        }
    }

    /// Focus and expose at a point the user tapped in the preview (0-1, sensor space).
    func focus(at point: CGPoint) {
        sessionQueue.async {
            guard let device = self.device, (try? device.lockForConfiguration()) != nil else { return }
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) { device.focusMode = .autoFocus }
            }
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                if device.isExposureModeSupported(.autoExpose) { device.exposureMode = .autoExpose }
            }
        }
    }

    // MARK: - Encoder

    // The encoder lives on `outputQueue`, the queue the camera delivers frames on:
    // start, encode, stop and restart all run there and nowhere else. VideoToolbox
    // does not tolerate a session being completed and invalidated on one thread
    // while frames are still being submitted on another -- that is what used to
    // hang `stop()` on the session queue when the last reader hung up, after which
    // every exposure, white balance and rotation change queued behind it was
    // accepted with `ok` and never applied. The session queue now only configures
    // the camera, and nothing it waits on can block.

    private func startEncoder() {
        guard !encoderRunning, let device else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let portrait = rotation % 180 != 0
        var config = VideoEncoder.Config()
        config.codec = codec
        config.width = portrait ? dimensions.height : dimensions.width
        config.height = portrait ? dimensions.width : dimensions.height
        config.bitrate = bitrateMbps * 1_000_000
        config.frameRate = frameRate

        do {
            try encoder.start(config)
            let hasAudio = audioInput != nil
            // Queued ahead of the first new access unit, which cannot reach the
            // mux queue until the next frame is encoded on this queue.
            muxQueue.async {
                self.muxer = TSMuxer(codec: self.codec, hasAudio: hasAudio)
                self.ptsBase = nil
            }
            audioQueue.async { self.audioEncoder.stop() }
            forceKeyframe = true
            encoderRunning = true
        } catch {
            DispatchQueue.main.async { self.status = error.localizedDescription }
        }
    }

    private func stopEncoder() {
        guard encoderRunning else { return }
        encoder.stop()
        audioQueue.async { self.audioEncoder.stop() }
        encoderRunning = false
    }

    private func restartEncoder() {
        outputQueue.async { self.restartEncoderIfRunning() }
    }

    private func restartEncoderIfRunning() {
        guard encoderRunning else { return }
        stopEncoder()
        // Changing orientation, size, frame rate or codec changes the stream
        // itself. Cut the readers so they redial and see the new format, rather
        // than sitting on a connection whose shape silently changed underneath.
        server.resetClients()
        startEncoder()
    }

    private func handleAccessUnit(_ annexB: [UInt8], pts: CMTime, keyframe: Bool) {
        muxQueue.async {
            // The first picture sets zero on the stream's clock; the microphone is
            // measured against the same base, so the two land on one timeline.
            if self.ptsBase == nil { self.ptsBase = pts }
            let ticks = self.ticks(for: pts)
            self.server.broadcast(self.muxer.mux(accessUnit: annexB, pts90k: ticks, keyframe: keyframe),
                                  keyframe: keyframe)
        }
    }

    private func handleAudioFrame(_ adts: [UInt8], pts: CMTime) {
        muxQueue.async {
            // Audio from before the first picture has no base to sit on. There is
            // no point holding it: the video is what a reader is waiting for.
            guard self.ptsBase != nil else { return }
            let data = self.muxer.mux(adtsFrame: adts, pts90k: self.ticks(for: pts))
            guard !data.isEmpty else { return }
            self.server.broadcast(data, keyframe: false)
        }
    }

    /// 90 kHz ticks since the first picture. Call on `muxQueue`.
    private func ticks(for pts: CMTime) -> Int64 {
        guard let base = ptsBase else { return 0 }
        return Int64((CMTimeGetSeconds(CMTimeSubtract(pts, base)) * 90_000).rounded())
    }
}

// MARK: - Frame delivery

extension CaptureController: AVCaptureVideoDataOutputSampleBufferDelegate,
                             AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // One delegate method serves both outputs; they arrive on their own queues.
        if output === audioOutput {
            guard encoderRunning else { return }
            audioEncoder.encode(sampleBuffer)
            return
        }

        let now = CACurrentMediaTime()
        frameTimestamps.append(now)
        frameTimestamps.removeAll { now - $0 > 1 }
        let rate = Double(frameTimestamps.count)
        DispatchQueue.main.async { self.measuredFPS = rate }

        guard encoderRunning, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let key = forceKeyframe
        forceKeyframe = false
        encoder.encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), forceKeyframe: key)
    }
}
