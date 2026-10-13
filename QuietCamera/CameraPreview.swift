import AVFoundation
import SwiftUI
import UIKit

/// The preview has its own connection. Its rotation and mirroring do not change
/// the orientation of the actual photo, which the capture controller configures.
@MainActor
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    let isFrontCamera: Bool

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.videoGravity = .resizeAspect
        view.previewLayer.session = session
        view.isFrontCamera = isFrontCamera
        view.setDevice(device)
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.isFrontCamera = isFrontCamera
        uiView.setDevice(device)
        uiView.updateConnection()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass {
            AVCaptureVideoPreviewLayer.self
        }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }

        var isFrontCamera = false
        private var cameraDevice: AVCaptureDevice?
        private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
        private var rotationObservation: NSKeyValueObservation?
        private var previewRotationAngle: CGFloat?

        func setDevice(_ device: AVCaptureDevice?) {
            guard cameraDevice?.uniqueID != device?.uniqueID else { return }
            rotationObservation?.invalidate()
            rotationObservation = nil
            rotationCoordinator = nil
            cameraDevice = device
            previewRotationAngle = nil
            guard let device else { return }

            let coordinator = AVCaptureDevice.RotationCoordinator(
                device: device,
                previewLayer: previewLayer
            )
            rotationCoordinator = coordinator
            previewRotationAngle = coordinator.videoRotationAngleForHorizonLevelPreview
            let deviceID = device.uniqueID
            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview,
                options: [.initial, .new]
            ) { [weak self] coordinator, _ in
                let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                Task { @MainActor [weak self] in
                    guard let self, self.cameraDevice?.uniqueID == deviceID else { return }
                    self.previewRotationAngle = angle
                    self.updateConnection()
                }
            }
            updateConnection()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            updateConnection()
        }

        func updateConnection() {
            guard let connection = previewLayer.connection else { return }
            if let angle = previewRotationAngle,
               connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isFrontCamera
            }
        }
    }
}
