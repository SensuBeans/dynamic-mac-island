import AVFoundation
import SwiftUI

/// One-click webcam preview ("check yourself before the call").
final class MirrorController: ObservableObject {
    @Published var isRunning = false
    @Published var denied = false

    let session = AVCaptureSession()
    private var configured = false
    /// Serial queue so start/stop can never interleave — a stop racing a
    /// start on a concurrent queue left the session in a broken state.
    private let sessionQueue = DispatchQueue(label: "notchbook.mirror.session")

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else {
                    self.denied = true
                    return
                }
                if !self.configured {
                    self.session.sessionPreset = .medium
                    if let device = AVCaptureDevice.default(for: .video),
                       let input = try? AVCaptureDeviceInput(device: device),
                       self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.configured = true
                    }
                }
                guard self.configured else { return }
                self.sessionQueue.async {
                    if !self.session.isRunning { self.session.startRunning() }
                    DispatchQueue.main.async { self.isRunning = true }
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        mirror(layer)
        view.layer?.addSublayer(layer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let layer = nsView.layer?.sublayers?.first as? AVCaptureVideoPreviewLayer {
            layer.frame = nsView.bounds
            mirror(layer)
        }
    }

    private func mirror(_ layer: AVCaptureVideoPreviewLayer) {
        if let connection = layer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
    }
}
