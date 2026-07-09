import AVFoundation
import SwiftUI

/// TEMPORARY mirror diagnostics — appends to /tmp/notchbook-debug.log.
func mlog(_ s: String) {
    let line = "\(Date()) \(s)\n"
    let url = URL(fileURLWithPath: "/tmp/notchbook-debug.log")
    if let h = try? FileHandle(forWritingTo: url) {
        defer { try? h.close() }
        h.seekToEndOfFile()
        h.write(line.data(using: .utf8)!)
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// One-click webcam preview ("check yourself before the call").
final class MirrorController: ObservableObject {
    @Published var isRunning = false
    @Published var denied = false

    let session = AVCaptureSession()
    private var configured = false
    /// User intent, distinct from isRunning: start() flips it on before its
    /// async permission/session work, stop() flips it off — so a stop can
    /// cancel a start that hasn't finished yet (the old isRunning guard let
    /// an in-flight start leave the camera on after the island closed).
    private var wantsRunning = false
    /// Serial queue so start/stop can never interleave — a stop racing a
    /// start on a concurrent queue left the session in a broken state.
    private let sessionQueue = DispatchQueue(label: "notchbook.mirror.session")

    /// Restart after a collapse: only if permission is already granted, so
    /// re-expanding the island can never surprise-prompt for the camera.
    func resumeIfAuthorized() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        mlog("resumeIfAuthorized status=\(status.rawValue)")
        if status == .authorized {
            start()
        }
    }

    func start() {
        mlog("start() called")
        wantsRunning = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                mlog("start: granted=\(granted) wantsRunning=\(self.wantsRunning) configured=\(self.configured)")
                guard granted else {
                    self.denied = true
                    return
                }
                guard self.wantsRunning else { return }
                if !self.configured {
                    self.session.sessionPreset = .medium
                    if let device = AVCaptureDevice.default(for: .video),
                       let input = try? AVCaptureDeviceInput(device: device),
                       self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.configured = true
                    }
                    mlog("start: configure done configured=\(self.configured)")
                }
                guard self.configured else { return }
                self.sessionQueue.async {
                    if !self.session.isRunning { self.session.startRunning() }
                    let running = self.session.isRunning
                    DispatchQueue.main.async {
                        mlog("start: session.isRunning=\(running) wantsRunning=\(self.wantsRunning)")
                        if self.wantsRunning { self.isRunning = true }
                    }
                }
            }
        }
    }

    func stop() {
        mlog("stop() called (was isRunning=\(isRunning) wantsRunning=\(wantsRunning))")
        wantsRunning = false
        isRunning = false
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    var debugState: String {
        "auth=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue) "
        + "configured=\(configured) wantsRunning=\(wantsRunning) "
        + "isRunning=\(isRunning) session.isRunning=\(session.isRunning) denied=\(denied)"
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
