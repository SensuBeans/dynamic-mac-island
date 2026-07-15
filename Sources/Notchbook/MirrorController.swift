import AVFoundation
import SwiftUI

/// One-click webcam preview ("check yourself before the call").
final class MirrorController: NSObject, ObservableObject {
    @Published var isRunning = false
    @Published var denied = false
    /// No camera device, or the input couldn't be added — the mirror can never
    /// start, so the UI shows an error instead of a dead "Show Mirror" button.
    @Published var unavailable = false

    let session = AVCaptureSession()
    /// ONE preview layer for the app's lifetime. Creating a fresh layer per
    /// tab visit re-plumbed the running session's connection graph each time,
    /// which made AVFoundation throw runtime errors on the second visit —
    /// camera "running" but drawing nothing (a dead mirror page). Host views
    /// borrow this layer; the session graph never changes after setup.
    lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()
    private var configured = false
    /// Settings-driven: selected camera `uniqueID` (empty = system default) and
    /// whether the preview is horizontally mirrored (selfie view).
    var preferredCameraID = ""
    var mirrored = true

    /// The device to capture from: the preferred camera if still present, else
    /// the system default.
    private func resolveDevice() -> AVCaptureDevice? {
        if !preferredCameraID.isEmpty,
           let d = AVCaptureDevice(uniqueID: preferredCameraID) { return d }
        return AVCaptureDevice.default(for: .video)
    }

    /// Apply the current mirroring choice to the (single, persistent) preview
    /// connection. No-op until the session graph exists.
    private func applyMirroring() {
        if let c = previewLayer.connection, c.isVideoMirroringSupported {
            c.automaticallyAdjustsVideoMirroring = false
            c.isVideoMirrored = mirrored
        }
    }

    /// Switch the active camera. Reconfigures only the session INPUT on the
    /// session queue — the session and the one preview layer are untouched.
    func selectCamera(_ id: String) {
        preferredCameraID = id
        sessionQueue.async {
            guard self.configured else { return }  // picked up on next start()
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            if let device = self.resolveDevice(),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            self.session.commitConfiguration()
            DispatchQueue.main.async { self.applyMirroring() }
        }
    }

    func setMirrored(_ on: Bool) {
        mirrored = on
        DispatchQueue.main.async { self.applyMirroring() }
    }
    /// User intent, distinct from isRunning: start() flips it on before its
    /// async permission/session work, stop() flips it off — so a stop can
    /// cancel a start that hasn't finished yet (the old isRunning guard let
    /// an in-flight start leave the camera on after the island closed).
    private var wantsRunning = false
    /// Serial queue so start/stop can never interleave — a stop racing a
    /// start on a concurrent queue left the session in a broken state.
    private let sessionQueue = DispatchQueue(label: "notchbook.mirror.session")

    override init() {
        super.init()
        // The session can die under us (another app grabs the camera, a
        // runtime error). Without these the tab keeps showing a dead preview
        // until relaunch — recover whenever the user still wants the camera.
        let center = NotificationCenter.default
        center.addObserver(forName: .AVCaptureSessionRuntimeError,
                           object: session, queue: .main) { [weak self] _ in
            guard let self, self.wantsRunning else { return }
            self.isRunning = false
            // Delayed single retry — an immediate restart here once produced
            // a tight error→restart loop that recreated the preview per tick.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self, self.wantsRunning, !self.isRunning else { return }
                self.start()
            }
        }
        center.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                           object: session, queue: .main) { [weak self] _ in
            guard let self, self.wantsRunning else { return }
            self.sessionQueue.async {
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    /// Restart after a collapse: only if permission is already granted, so
    /// re-expanding the island can never surprise-prompt for the camera.
    func resumeIfAuthorized() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            start()
        }
    }

    func start() {
        wantsRunning = true
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self else { return }
            guard granted else {
                DispatchQueue.main.async { self.denied = true }
                return
            }
            // Device discovery, input creation and `addInput` all run on the
            // session queue (same thread as startRunning) so the first mirror
            // open never freezes the island animation on the main thread.
            self.sessionQueue.async {
                guard self.wantsRunning else { return }
                if !self.configured {
                    self.session.sessionPreset = .medium
                    if let device = self.resolveDevice(),
                       let input = try? AVCaptureDeviceInput(device: device),
                       self.session.canAddInput(input) {
                        self.session.addInput(input)
                        self.configured = true
                    }
                }
                let ready = self.configured
                if ready && !self.session.isRunning { self.session.startRunning() }
                DispatchQueue.main.async {
                    self.denied = false
                    guard self.wantsRunning else { return }
                    guard ready else {
                        self.unavailable = true
                        return
                    }
                    self.unavailable = false
                    self.isRunning = true
                    // Selfie mirroring — the connection only exists once the
                    // session is configured, so apply it here.
                    self.applyMirroring()
                }
            }
        }
    }

    func stop() {
        wantsRunning = false
        isRunning = false
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let layer: AVCaptureVideoPreviewLayer

    /// Hosts the controller's persistent preview layer (adopting a layer
    /// steals it from any previous superlayer, so at most one view shows it)
    /// and sizes it in layout() so it can never be left at a stale frame —
    /// autoresizingMask alone missed views created at their final size.
    final class PreviewView: NSView {
        let previewLayer: AVCaptureVideoPreviewLayer

        init(layer: AVCaptureVideoPreviewLayer) {
            previewLayer = layer
            super.init(frame: .zero)
            wantsLayer = true
            self.layer?.addSublayer(layer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds
            CATransaction.commit()
        }
    }

    func makeNSView(context: Context) -> PreviewView {
        PreviewView(layer: layer)
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.needsLayout = true
    }
}
