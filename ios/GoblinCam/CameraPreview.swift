import SwiftUI
import AVFoundation

/// Live preview. Tapping converts the point into sensor space and drives
/// focus/exposure there.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let rotation: Int
    let onTap: (CGPoint) -> Void

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        var onTap: ((CGPoint) -> Void)?

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            let point = previewLayer.captureDevicePointConverted(fromLayerPoint: recognizer.location(in: self))
            onTap?(point)
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        view.onTap = onTap
        view.addGestureRecognizer(UITapGestureRecognizer(target: view, action: #selector(PreviewView.handleTap(_:))))
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.onTap = onTap
        guard let connection = view.previewLayer.connection else { return }
        let angle = CGFloat(rotation)
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
    }
}
