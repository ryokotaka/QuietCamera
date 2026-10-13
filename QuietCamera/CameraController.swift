import AVFoundation
import Combine
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers

struct CameraState: Sendable {
    var isRunning = false
    var isBusy = false
    var isConfigured = false
    var canSwitchCamera = false
    var isFrontCamera = false
    var zoomFactor: CGFloat = 1
    var minZoomFactor: CGFloat = 1
    var maxZoomFactor: CGFloat = 1
    // Uses a bounded app default when the format has no system recommendation.
    var systemRecommendedMaxZoomFactor: CGFloat = 1
    var isZoomed = false
    var cameraName = "背面カメラ"
    var requestedResolution = "準備中"
    var codecName = "HEIC優先"
    var silenceStatus = "確認中"
    var supportsSilentCapture = false
    var isAudioInputActive = false
    var supports48MPTest = false
    var livePhotoTestResult: String?
    var callbackTestResult: String?
    var message = "カメラを準備しています"
    var errorMessage: String?
    var needsSettings = false
    var lastSavedResolution: String?
    var pendingSave = false
}

/// UI and authorization live on the main actor; all session changes use one serial queue.
@MainActor
final class CameraController: ObservableObject {
    @Published private(set) var state = CameraState()
    @Published private(set) var pendingSave = false
    @Published private(set) var currentDevice: AVCaptureDevice?
    // Suppression is automatic. Historical audio/Live Photo experiments stay disabled.
    private let audioExperimentEnabled = false
    private let livePhotoExperimentEnabled = false
    @Published private(set) var isRequestingMicrophone = false
    let session: AVCaptureSession
    private let engine: CameraEngine
    private var activationTask: Task<Void, Never>?
    private var wantsActive = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        let engine = CameraEngine()
        self.engine = engine
        session = engine.session
        engine.onState = { [weak self] newState in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.state = newState
                self.pendingSave = newState.pendingSave
                if !newState.isBusy { self.endBackgroundTask() }
            }
        }
        engine.onDevice = { [weak self] device in
            Task { @MainActor [weak self] in
                self?.currentDevice = device
                self?.rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            }
        }
    }

    func activate() {
        wantsActive = true
        guard activationTask == nil else { return }
        activationTask = Task { [weak self] in
            guard let self else { return }
            var cameraAllowed = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                cameraAllowed = await AVCaptureDevice.requestAccess(for: .video)
            }
            if cameraAllowed, PHPhotoLibrary.authorizationStatus(for: .addOnly) == .notDetermined {
                // Resolve permission before capture, especially before creating a deferred proxy.
                _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            }
            self.activationTask = nil
            guard self.wantsActive else { return }
            if cameraAllowed {
                self.engine.setActive(true)
            } else {
                self.engine.showError("カメラの使用を許可してください。設定から変更できます。", needsSettings: true)
            }
        }
    }

    func deactivate() {
        wantsActive = false
        engine.setActive(false)
    }

    func capture() {
        guard wantsActive, state.isRunning, !state.isBusy, !pendingSave, !isRequestingMicrophone else { return }
        guard Self.canAddPhotos else {
            engine.showError("写真への追加を許可してください。設定 → アプリ → Quiet Camera → 写真で変更できます。", needsSettings: true)
            return
        }
        let useAudioExperiment = audioExperimentEnabled && !livePhotoExperimentEnabled && !state.supportsSilentCapture
        if useAudioExperiment {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                isRequestingMicrophone = true
                Task { [weak self] in
                    let allowed = await AVCaptureDevice.requestAccess(for: .audio)
                    guard let self else { return }
                    self.isRequestingMicrophone = false
                    if !allowed {
                        self.engine.showError("このテストにはマイクの許可が必要です。音声は保存・送信しません。", needsSettings: true)
                    }
                    // Permission is separate from capture. Require another deliberate shutter press.
                }
                return
            case .authorized: break
            default:
                engine.showError("このテストにはマイクの許可が必要です。設定から変更するか、テストをOFFにしてください。", needsSettings: true)
                return
            }
        }
        beginBackgroundTask()
        let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
        engine.capture(rotationAngle: angle, audioExperimentEnabled: useAudioExperiment, livePhotoExperimentEnabled: livePhotoExperimentEnabled)
    }

    func switchCamera() { engine.switchCamera() }
    func clearError() { engine.clearError() }

    func setZoomFactor(_ factor: CGFloat) {
        guard factor.isFinite, wantsActive, state.isRunning, !state.isBusy,
              !pendingSave, !isRequestingMicrophone, let deviceID = currentDevice?.uniqueID else { return }
        engine.setZoomFactor(factor, expectedDeviceID: deviceID)
    }

    func resetZoom() { setZoomFactor(1) }

    func retrySave() {
        guard pendingSave, !state.isBusy else { return }
        guard Self.canAddPhotos else {
            engine.showError("写真への追加を許可してから保存を再試行してください。", needsSettings: true)
            return
        }
        beginBackgroundTask()
        engine.retrySave()
    }

    private static var canAddPhotos: Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        return status == .authorized || status == .limited
    }

    private func beginBackgroundTask() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "SaveCameraPhoto") { [weak self] in
            Task { @MainActor in self?.endBackgroundTask() }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

private enum CameraFailure: LocalizedError {
    case unavailable, connection, representation
    case livePhotoTest(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return "カメラが見つかりません。撮影はiPhone実機でお試しください。"
        case .connection: return "カメラを接続できませんでした。アプリを開き直してください。"
        case .representation: return "写真データを作成できませんでした。もう一度撮影してください。"
        case .livePhotoTest(let message): return message
        }
    }
}

private struct CapturedPhoto {
    let data: Data
    let isProxy: Bool
    let fileExtension: String
    let contentType: String
    let resolution: String
    let date: Date
    let livePhotoTestResolution: String?
    let requestedResolution: String?
    let captureZoomFactor: CGFloat
    let resolvedResolution: String
    var callbackTestSummary: String? = nil

    var livePhotoResultSummary: String? {
        guard let resolution = livePhotoTestResolution else { return nil }
        return captureZoomFactor > 1.001 ? "実画像 \(resolution)" : "48MP維持を確認 · \(resolution)"
    }
}

private struct LivePhotoAttempt {
    let baseline: CMVideoDimensions
    let wasLivePhotoEnabled: Bool
    let wasLivePhotoSuspended: Bool
    let wasDeferredEnabled: Bool
    let movieURL: URL
}

/// Mutable engine state is confined to `queue`, including delegate and Photos completions.
private final class CameraEngine: @unchecked Sendable {
    let session = AVCaptureSession()
    var onState: ((CameraState) -> Void)?
    var onDevice: ((AVCaptureDevice) -> Void)?
    private let queue = DispatchQueue(label: "QuietCamera.capture", qos: .userInitiated)
    private let output = AVCapturePhotoOutput()
    private lazy var audioExperiment = CaptureAudioExperiment(queue: queue)
    private var input: AVCaptureDeviceInput?
    private var state = CameraState()
    private var wantsActive = false
    private var processor: PhotoProcessor?
    private var pendingPhoto: CapturedPhoto?
    private var captureResult: Result<CapturedPhoto, Error>?
    private var livePhotoAttempt: LivePhotoAttempt?
    private var configurationRestorationError: String?
    private var isCallbackTestCapture = false
    private var configuredMaximumDimensions = CMVideoDimensions(width: 0, height: 0)
    private var observers: [NSObjectProtocol] = []

    init() {
        audioExperiment.onInterruption = { [weak self] in
            guard let self else { return }
            self.state.isAudioInputActive = false
            self.state.message = "音声入力が中断されました。消音テストは停止しました。"
            self.publish()
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.state.isRunning = false
                self.state.message = "カメラが一時停止中です。利用可能になると再開します。"
                self.publish()
            }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.startIfNeeded() }
        })
        observers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] notification in
            guard let self else { return }
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError
            self.queue.async {
                self.state.isRunning = false
                if error?.code == .mediaServicesWereReset, self.wantsActive {
                    self.startIfNeeded()
                } else {
                    self.fail(error?.localizedDescription ?? "カメラでエラーが発生しました。アプリを開き直してください。")
                }
            }
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func setActive(_ active: Bool) {
        queue.async {
            self.wantsActive = active
            if !active {
                self.audioExperiment.stop()
                self.state.isAudioInputActive = false
            }
            if active { self.startIfNeeded() } else { self.stopIfNeeded() }
        }
    }

    func showError(_ message: String, needsSettings: Bool) {
        queue.async { self.fail(message, needsSettings: needsSettings) }
    }

    func clearError() {
        queue.async {
            self.state.errorMessage = nil
            self.state.needsSettings = false
            self.publish()
        }
    }

    private func startIfNeeded() {
        guard wantsActive else { return }
        do {
            if !state.isConfigured { try configure() }
            if !session.isRunning { session.startRunning() }
            state.isRunning = session.isRunning && !session.isInterrupted
            refreshCapabilities()
            if state.isRunning, !state.isBusy, pendingPhoto == nil {
                state.message = "撮影できます"
                state.errorMessage = nil
                state.needsSettings = false
            }
            publish()
        } catch { fail(error.localizedDescription) }
    }

    private func stopIfNeeded() {
        // Allow an in-progress capture to deliver its file before stopping the session.
        guard !wantsActive, processor == nil else { return }
        if session.isRunning { session.stopRunning() }
        state.isRunning = false
        publish()
    }

    private func configure() throws {
        removeAbandonedLivePhotoMovies()
        guard let device = camera(at: .back) ?? camera(at: .front) else { throw CameraFailure.unavailable }
        let newInput = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canSetSessionPreset(.photo) else { throw CameraFailure.connection }
        session.sessionPreset = .photo
        // Audio is managed only by the opt-in experiment; photo dimensions stay unchanged.
        session.automaticallyConfiguresApplicationAudioSession = false
        guard session.canAddInput(newInput) else { throw CameraFailure.connection }
        session.addInput(newInput)
        guard session.canAddOutput(output) else {
            session.removeInput(newInput)
            throw CameraFailure.connection
        }
        session.addOutput(output)
        input = newInput
        configureOutput(for: device)
        state.isConfigured = true
        state.canSwitchCamera = camera(at: .front) != nil && camera(at: .back) != nil
        onDevice?(device)
    }

    private func removeAbandonedLivePhotoMovies() {
        // Recover only this app's UUID-named test movies after an interrupted prior launch.
        let prefix = "QuietCamera-LiveTest-"
        do {
            let files = try FileManager.default.contentsOfDirectory(at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            for file in files where file.pathExtension == "mov" && file.lastPathComponent.hasPrefix(prefix) {
                let identifier = String(file.deletingPathExtension().lastPathComponent.dropFirst(prefix.count))
                guard UUID(uuidString: identifier) != nil,
                      try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                do { try FileManager.default.removeItem(at: file) }
                catch { print("[LivePhoto48MP] abandoned movie cleanup failed: \(error.localizedDescription)") }
            }
        } catch { print("[LivePhoto48MP] temporary movie scan failed: \(error.localizedDescription)") }
    }

    private func camera(at position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        // Stay on the main wide camera; user-selected zoom is applied by the capture device.
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position)
    }

    private func configureOutput(for device: AVCaptureDevice) {
        output.maxPhotoQualityPrioritization = .quality
        // Keep the .photo preset: selecting an arbitrary activeFormat can disable 24/48 MP capture.
        if let dimensions = device.activeFormat.supportedMaxPhotoDimensions.max(by: { pixelArea($0) < pixelArea($1) }) {
            output.maxPhotoDimensions = dimensions
        }
        configuredMaximumDimensions = output.maxPhotoDimensions
        output.isAutoDeferredPhotoDeliveryEnabled = output.isAutoDeferredPhotoDeliverySupported
        if output.isFastCapturePrioritizationSupported { output.isFastCapturePrioritizationEnabled = false }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if let range = zoomRange(for: device) { device.videoZoomFactor = min(max(1, range.lowerBound), range.upperBound) }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
        } catch {
            // Capture remains usable with the device defaults if a configuration lock is unavailable.
        }
        refreshCapabilities()
    }

    private func refreshCapabilities() {
        guard let device = input?.device else { return }
        state.isFrontCamera = device.position == .front
        state.zoomFactor = device.videoZoomFactor
        state.isZoomed = state.zoomFactor > 1.001
        let range = zoomRange(for: device)
        state.minZoomFactor = range?.lowerBound ?? state.zoomFactor
        state.maxZoomFactor = range?.upperBound ?? state.zoomFactor
        state.systemRecommendedMaxZoomFactor = range.map { recommendedMaximumZoomFactor(for: device, within: $0) } ?? state.zoomFactor
        state.cameraName = "\(state.isFrontCamera ? "前面カメラ" : "背面カメラ") · \(zoomDescription(state.zoomFactor))"
        state.requestedResolution = resolutionDescription(output.maxPhotoDimensions)
        state.codecName = output.availablePhotoCodecTypes.contains(.hevc) ? "HEIC" : "JPEG"
        state.supportsSilentCapture = output.isShutterSoundSuppressionSupported
        state.supports48MPTest = device.position == .back && pixelArea(configuredMaximumDimensions) >= 48_000_000
        state.silenceStatus = state.supportsSilentCapture ? "消音設定は常時ON · 公式対応" : "消音設定は常時ON · 効果は端末によります"
    }

    private func zoomRange(for device: AVCaptureDevice) -> ClosedRange<CGFloat>? {
        let values = [device.minAvailableVideoZoomFactor, device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor]
        guard values.allSatisfy({ $0.isFinite }) else { return nil }
        let lower = max(1, values[0])
        let upper = min(values[1], values[2])
        guard upper >= lower else { return nil }
        return lower...upper
    }

    private func recommendedMaximumZoomFactor(for device: AVCaptureDevice, within range: ClosedRange<CGFloat>) -> CGFloat {
        if #available(iOS 18.0, *), let recommendation = device.activeFormat.systemRecommendedVideoZoomRange,
           recommendation.lowerBound.isFinite, recommendation.upperBound.isFinite {
            return min(max(recommendation.upperBound, range.lowerBound), range.upperBound)
        }
        // This fallback is an app UI choice, not a claim that the system recommended 10×.
        return min(max(10, range.lowerBound), range.upperBound)
    }

    func setZoomFactor(_ factor: CGFloat, expectedDeviceID: String) {
        guard factor.isFinite else { return }
        queue.async {
            guard self.wantsActive, self.session.isRunning, !self.session.isInterrupted,
                  self.state.isConfigured, !self.state.isBusy, self.pendingPhoto == nil,
                  self.configurationRestorationError == nil,
                  let device = self.input?.device, device.uniqueID == expectedDeviceID else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                // Available limits can change, so read them again while holding the device lock.
                guard let range = self.zoomRange(for: device) else { return }
                let bounded = min(max(factor, range.lowerBound), range.upperBound)
                let normalized: CGFloat = bounded <= 1.005 ? 1 : (bounded * 100).rounded() / 100
                device.videoZoomFactor = min(max(normalized, range.lowerBound), range.upperBound)
                self.refreshCapabilities()
                self.publish()
            } catch {
                self.fail("ズームを変更できませんでした。もう一度お試しください。")
            }
        }
    }

    func switchCamera() {
        queue.async {
            guard self.state.isConfigured, !self.state.isBusy, self.pendingPhoto == nil,
                  let oldInput = self.input,
                  let device = self.camera(at: oldInput.device.position == .back ? .front : .back) else { return }
            self.state.isBusy = true
            self.state.message = "カメラを切り替えています"
            self.publish()
            do {
                let newInput = try AVCaptureDeviceInput(device: device)
                self.session.beginConfiguration()
                self.session.removeInput(oldInput)
                if self.session.canAddInput(newInput) {
                    self.session.addInput(newInput)
                    self.input = newInput
                    self.configureOutput(for: device)
                    self.session.commitConfiguration()
                    self.onDevice?(device)
                    self.state.message = "撮影できます"
                } else {
                    if self.session.canAddInput(oldInput) {
                        self.session.addInput(oldInput)
                        self.configureOutput(for: oldInput.device)
                    }
                    self.session.commitConfiguration()
                    throw CameraFailure.connection
                }
                self.state.isBusy = false
                self.state.isRunning = self.session.isRunning && !self.session.isInterrupted
                self.publish()
            } catch {
                self.state.isBusy = false
                self.fail(error.localizedDescription)
            }
        }
    }

    func capture(rotationAngle: CGFloat, audioExperimentEnabled: Bool, livePhotoExperimentEnabled: Bool) {
        queue.async { [self] in
            guard self.wantsActive, self.session.isRunning, !self.session.isInterrupted,
                  !self.state.isBusy, self.pendingPhoto == nil else { self.publish(); return }
            if let configurationError = self.configurationRestorationError {
                self.fail(configurationError)
                return
            }
            let officialSuppressionSupported = self.output.isShutterSoundSuppressionSupported
            let tryExperimentalSilencing = !livePhotoExperimentEnabled && !officialSuppressionSupported
            let requires48MPBaseline = self.input?.device.position == .back && pixelArea(self.configuredMaximumDimensions) >= 48_000_000
            let useAudioExperiment = audioExperimentEnabled && !livePhotoExperimentEnabled && !tryExperimentalSilencing && !officialSuppressionSupported
            if requires48MPBaseline {
                self.state.isBusy = true
                self.state.errorMessage = nil
                self.state.message = "撮影の準備をしています…"
                self.publish()
                do {
                    try self.validateBack48MPSettings()
                } catch {
                    let message = error.localizedDescription
                    self.state.callbackTestResult = "撮影中止 · \(message)"
                    self.state.isBusy = false
                    self.fail(message)
                    return
                }
            }
            if livePhotoExperimentEnabled {
                do {
                    try self.prepareLivePhotoAttempt()
                } catch {
                    let restorationError = self.restoreLivePhotoConfiguration()
                    let message = [error.localizedDescription, restorationError?.localizedDescription].compactMap { $0 }.joined(separator: "\n")
                    self.state.livePhotoTestResult = "テスト中止 · \(message)"
                    self.fail(message)
                    return
                }
            }
            // Capture configuration can rebuild the pipeline; obtain its current connection afterward.
            guard self.session.isRunning, !self.session.isInterrupted,
                  let connection = self.output.connection(with: .video), connection.isActive else {
                let message = "カメラの準備ができていません。少し待ってから撮影してください。"
                let restorationError = self.restoreLivePhotoConfiguration()
                if livePhotoExperimentEnabled { self.state.livePhotoTestResult = "テスト中止 · \(message)" }
                if tryExperimentalSilencing { self.state.callbackTestResult = "撮影中止 · \(message)" }
                self.state.isBusy = false
                self.fail(restorationError?.localizedDescription ?? message)
                return
            }
            if connection.isVideoRotationAngleSupported(rotationAngle) { connection.videoRotationAngle = rotationAngle }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            let codec: AVVideoCodecType = self.output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
            let settings = AVCapturePhotoSettings(format: [
                AVVideoCodecKey: codec,
                AVVideoCompressionPropertiesKey: [AVVideoQualityKey: 1.0]
            ])
            settings.maxPhotoDimensions = self.output.maxPhotoDimensions
            settings.photoQualityPrioritization = .quality
            if let attempt = self.livePhotoAttempt {
                // A non-nil movie URL requests the Live Photo path. The movie is temporary only.
                settings.livePhotoMovieFileURL = attempt.movieURL
            }
            // Never set this flag on an unsupported output: AVFoundation would raise an exception.
            if self.output.isShutterSoundSuppressionSupported { settings.isShutterSoundSuppressionEnabled = true }
            if self.output.supportedFlashModes.contains(.off) { settings.flashMode = .off }
            self.refreshCapabilities()
            self.state.isBusy = true
            self.state.errorMessage = nil
            self.state.message = "撮影しています…"
            self.isCallbackTestCapture = tryExperimentalSilencing
            if tryExperimentalSilencing {
                let zoom = self.input?.device.videoZoomFactor ?? 1
                self.state.callbackTestResult = "\(zoomDescription(zoom)) · 最大要求: \(resolutionDescription(settings.maxPhotoDimensions)) · 撮影通知待ち"
                print("[CameraCapture] requested \(resolutionDescription(settings.maxPhotoDimensions)); strictBack48=\(requires48MPBaseline); zoom=\(zoom); deferred=\(self.output.isAutoDeferredPhotoDeliveryEnabled); microphone=false; LivePhoto=false")
            }
            self.captureResult = nil
            self.publish()
            if useAudioExperiment {
                self.audioExperiment.start { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success:
                        guard self.wantsActive, self.session.isRunning, !self.session.isInterrupted,
                              connection.isActive else {
                            self.audioExperiment.stop()
                            self.state.isBusy = false
                            self.state.isAudioInputActive = false
                            self.publish()
                            return
                        }
                        self.state.isAudioInputActive = true
                        self.state.message = "マイク使用中・音声保存なしで撮影しています…"
                        self.submitCapture(settings: settings, requires48MPBaseline: requires48MPBaseline, tryExperimentalSilencing: false)
                    case .failure(let error):
                        self.state.isBusy = false
                        self.state.isAudioInputActive = false
                        self.fail("消音テストを開始できなかったため、撮影を中止しました。\n\(error.localizedDescription)")
                    }
                }
            } else {
                self.submitCapture(settings: settings, requires48MPBaseline: requires48MPBaseline, tryExperimentalSilencing: tryExperimentalSilencing)
            }
        }
    }

    private func validateBack48MPSettings() throws {
        let baseline = output.maxPhotoDimensions
        guard let device = input?.device, device.position == .back,
              pixelArea(baseline) >= 48_000_000,
              device.activeFormat.supportedMaxPhotoDimensions.contains(where: { sameDimensions($0, baseline) }),
              session.sessionPreset == .photo, output.maxPhotoQualityPrioritization == .quality else {
            throw CameraFailure.livePhotoTest("背面カメラの48MP設定を確認できなかったため、撮影を中止しました。")
        }
        // Preserve the normal deferred setting so Photos can finish a delivered photo proxy.
        print("[CameraCapture] preserving deferred=\(output.isAutoDeferredPhotoDeliveryEnabled); baseline=\(resolutionDescription(baseline))")
    }

    private func prepareLivePhotoAttempt() throws {
        guard let device = input?.device, device.position == .back,
              pixelArea(output.maxPhotoDimensions) >= 48_000_000 else {
            throw CameraFailure.livePhotoTest("このテストは48MP対応の背面カメラでのみ実行できます。")
        }
        let baseline = output.maxPhotoDimensions
        guard device.activeFormat.supportedMaxPhotoDimensions.contains(where: { sameDimensions($0, baseline) }),
              session.sessionPreset == .photo, output.maxPhotoQualityPrioritization == .quality else {
            throw CameraFailure.livePhotoTest("通常撮影の48MP設定を確認できないため、撮影を中止しました。")
        }
        guard output.isLivePhotoCaptureSupported else {
            throw CameraFailure.livePhotoTest("現在の48MP設定ではLive Photo経路に対応していません。")
        }
        let attempt = LivePhotoAttempt(
            baseline: baseline,
            wasLivePhotoEnabled: output.isLivePhotoCaptureEnabled,
            wasLivePhotoSuspended: output.isLivePhotoCaptureEnabled && output.isLivePhotoCaptureSuspended,
            wasDeferredEnabled: output.isAutoDeferredPhotoDeliveryEnabled,
            movieURL: FileManager.default.temporaryDirectory.appendingPathComponent("QuietCamera-LiveTest-\(UUID().uuidString).mov")
        )
        livePhotoAttempt = attempt
        session.beginConfiguration()
        output.isAutoDeferredPhotoDeliveryEnabled = false
        output.isLivePhotoCaptureEnabled = true
        output.isLivePhotoCaptureSuspended = false
        session.commitConfiguration()
        guard output.isLivePhotoCaptureSupported, output.isLivePhotoCaptureEnabled,
              !output.isLivePhotoCaptureSuspended,
              device.activeFormat.supportedMaxPhotoDimensions.contains(where: { sameDimensions($0, baseline) }),
              sameDimensions(output.maxPhotoDimensions, baseline), session.sessionPreset == .photo,
              output.maxPhotoQualityPrioritization == .quality else {
            throw CameraFailure.livePhotoTest("Live Photoを有効にすると通常の48MP設定を維持できないため、撮影を中止しました。")
        }
        // maxPhotoDimensions is an upper bound, not a guarantee. Verify the delivered image too.
        state.livePhotoTestResult = "要求: \(resolutionDescription(baseline)) · 実画像の確認待ち"
        print("[LivePhoto48MP] requested \(resolutionDescription(baseline)); deferred=false; microphone=false")
    }

    @discardableResult
    private func restoreLivePhotoConfiguration() -> Error? {
        guard let attempt = livePhotoAttempt else { return nil }
        session.beginConfiguration()
        output.isLivePhotoCaptureEnabled = attempt.wasLivePhotoEnabled
        if attempt.wasLivePhotoEnabled { output.isLivePhotoCaptureSuspended = attempt.wasLivePhotoSuspended }
        output.isAutoDeferredPhotoDeliveryEnabled = attempt.wasDeferredEnabled && output.isAutoDeferredPhotoDeliverySupported
        session.commitConfiguration()
        if !sameDimensions(output.maxPhotoDimensions, attempt.baseline),
           input?.device.activeFormat.supportedMaxPhotoDimensions.contains(where: { sameDimensions($0, attempt.baseline) }) == true {
            session.beginConfiguration()
            output.maxPhotoDimensions = attempt.baseline
            session.commitConfiguration()
        }
        // Delete only the file URL created by this attempt, after all capture callbacks finished.
        if FileManager.default.fileExists(atPath: attempt.movieURL.path) {
            do { try FileManager.default.removeItem(at: attempt.movieURL) }
            catch { print("[LivePhoto48MP] temporary movie cleanup failed: \(error.localizedDescription)") }
        }
        livePhotoAttempt = nil
        refreshCapabilities()
        let restored = sameDimensions(output.maxPhotoDimensions, attempt.baseline)
            && input?.device.activeFormat.supportedMaxPhotoDimensions.contains(where: { sameDimensions($0, attempt.baseline) }) == true
            && output.isLivePhotoCaptureEnabled == attempt.wasLivePhotoEnabled
            && output.isAutoDeferredPhotoDeliveryEnabled == attempt.wasDeferredEnabled
            && session.sessionPreset == .photo && output.maxPhotoQualityPrioritization == .quality
        configurationRestorationError = restored ? nil : "通常撮影の48MP設定を完全に復元できませんでした。撮影を停止しました。アプリを終了して開き直してください。"
        return configurationRestorationError.map { CameraFailure.livePhotoTest($0) }
    }

    private func submitCapture(settings: AVCapturePhotoSettings, requires48MPBaseline: Bool, tryExperimentalSilencing: Bool) {
        let minimumDimensions = livePhotoAttempt?.baseline ?? (requires48MPBaseline ? settings.maxPhotoDimensions : nil)
        // Freeze the device's actual zoom for this request; later UI changes cannot relabel it.
        let captureZoomFactor = input?.device.videoZoomFactor ?? 1
        let processor = PhotoProcessor(requestedDimensions: settings.maxPhotoDimensions, minimumDimensions: minimumDimensions, movieURL: livePhotoAttempt?.movieURL, captureZoomFactor: captureZoomFactor, tryExperimentalSilencing: tryExperimentalSilencing, onCallbackUpdate: { [weak self] summary in
            guard let self else { return }
            self.queue.async {
                self.state.callbackTestResult = summary
                self.publish()
            }
        }, onResolved: { [weak self] dimensions in
            guard let self else { return }
            self.queue.async {
                if tryExperimentalSilencing {
                    self.state.callbackTestResult = "\(zoomDescription(captureZoomFactor)) · 完成予定: \(resolutionDescription(dimensions)) · 撮影通知待ち"
                } else if self.livePhotoAttempt != nil {
                    self.state.livePhotoTestResult = "処理予定: \(resolutionDescription(dimensions)) · 実画像の確認待ち"
                }
                self.publish()
            }
        }, onPhoto: { [weak self] result in
            guard let self else { return }
            self.queue.async { self.captureResult = result }
        }, onComplete: { [weak self] error in
            guard let self else { return }
            self.queue.async { self.finishCapture(error: error) }
        })
        self.processor = processor // Retain the delegate until didFinishCaptureFor.
        self.publish()
        self.output.capturePhoto(with: settings, delegate: processor)
    }

    private func finishCapture(error: Error?) {
        let wasLivePhotoTest = livePhotoAttempt != nil
        let wasCallbackTest = isCallbackTestCapture
        isCallbackTestCapture = false
        let restorationError = restoreLivePhotoConfiguration()
        audioExperiment.stop()
        state.isAudioInputActive = false
        processor = nil
        if let error = error ?? restorationError {
            state.isBusy = false
            if wasLivePhotoTest { state.livePhotoTestResult = "テスト失敗 · \(error.localizedDescription)" }
            if wasCallbackTest { state.callbackTestResult = "\(state.callbackTestResult ?? "通知テスト") · テスト失敗: \(error.localizedDescription)" }
            fail(error.localizedDescription)
        } else if let result = captureResult {
            switch result {
            case .success(let photo):
                if let summary = photo.livePhotoResultSummary {
                    state.livePhotoTestResult = "\(summary) · 保存中"
                }
                if let summary = photo.callbackTestSummary { state.callbackTestResult = "\(summary) · 保存中" }
                pendingPhoto = photo
                savePendingPhoto()
            case .failure(let error):
                state.isBusy = false
                if wasLivePhotoTest { state.livePhotoTestResult = "保存せず終了 · \(error.localizedDescription)" }
                if wasCallbackTest { state.callbackTestResult = "\(state.callbackTestResult ?? "通知テスト") · 保存せず終了: \(error.localizedDescription)" }
                fail(error.localizedDescription)
            }
        } else {
            state.isBusy = false
            if wasLivePhotoTest { state.livePhotoTestResult = "テスト失敗 · 写真データを確認できませんでした" }
            if wasCallbackTest { state.callbackTestResult = "\(state.callbackTestResult ?? "通知テスト") · 写真データを確認できませんでした" }
            fail(CameraFailure.representation.localizedDescription)
        }
        captureResult = nil
        stopIfNeeded()
    }

    func retrySave() {
        queue.async {
            guard !self.state.isBusy, self.pendingPhoto != nil else { return }
            self.savePendingPhoto()
        }
    }

    private func savePendingPhoto() {
        guard let photo = pendingPhoto else { return }
        state.isBusy = true
        state.pendingSave = true
        state.errorMessage = nil
        state.needsSettings = false
        state.message = "写真に保存しています…"
        publish()
        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.creationDate = photo.date
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = "QuietCamera-\(UUID().uuidString).\(photo.fileExtension)"
            options.uniformTypeIdentifier = photo.contentType
            // A proxy must be .photoProxy, otherwise Photos cannot finish high-quality processing.
            request.addResource(with: photo.isProxy ? .photoProxy : .photo, data: photo.data, options: options)
        } completionHandler: { [weak self] success, error in
            guard let self else { return }
            self.queue.async {
                self.state.isBusy = false
                if photo.callbackTestSummary != nil {
                    let resource = photo.isProxy ? "photoProxy" : "photo"
                    let result = error.map { "\(($0 as NSError).domain):\(($0 as NSError).code)" } ?? "none"
                    print("[CameraCapture] PhotosSave success=\(success); kind=\(resource); requested=\(photo.requestedResolution ?? "unknown"); zoom=\(photo.captureZoomFactor); resolved=\(photo.resolvedResolution); finalProcessingPending=\(photo.isProxy); error=\(result)")
                }
                if success {
                    self.pendingPhoto = nil
                    self.state.pendingSave = false
                    self.state.lastSavedResolution = photo.resolution
                    if let summary = photo.livePhotoResultSummary {
                        self.state.livePhotoTestResult = "\(summary) · 保存済み"
                    }
                    if let summary = photo.callbackTestSummary {
                        self.state.callbackTestResult = photo.isProxy ? "\(summary)・写真アプリで仕上げ待ち" : "\(summary) · 保存済み"
                    }
                    self.state.message = photo.isProxy ? "保存しました · 写真アプリで仕上げ待ち" : "写真に保存しました"
                    self.publish()
                } else {
                    if let summary = photo.livePhotoResultSummary {
                        self.state.livePhotoTestResult = "\(summary) · 保存の再試行が必要"
                    }
                    if let summary = photo.callbackTestSummary { self.state.callbackTestResult = "\(summary) · 保存の再試行が必要" }
                    let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
                    self.fail("保存できませんでした。アプリを閉じずに再試行してください。\n\(error?.localizedDescription ?? "写真の権限や空き容量をご確認ください。")", needsSettings: status == .denied || status == .restricted)
                }
            }
        }
    }

    private func fail(_ message: String, needsSettings: Bool = false) {
        state.errorMessage = message
        state.needsSettings = needsSettings
        state.message = message
        publish()
    }

    private func publish() { onState?(state) }
}

private final class PhotoProcessor: NSObject, AVCapturePhotoCaptureDelegate {
    let onPhoto: (Result<CapturedPhoto, Error>) -> Void
    let onComplete: (Error?) -> Void
    let onResolved: (CMVideoDimensions) -> Void
    let onCallbackUpdate: (String) -> Void
    private let requestedDimensions: CMVideoDimensions
    private let minimumDimensions: CMVideoDimensions?
    private let movieURL: URL?
    private let captureZoomFactor: CGFloat
    private let tryExperimentalSilencing: Bool
    private var willCaptureStatus: Int32?
    private var didCaptureStatus: Int32?
    private var captureDate = Date()
    private var photoResult: Result<CapturedPhoto, Error>?
    private var processingError: Error?
    private var movieError: Error?
    private var didProcessMovie = false

    init(requestedDimensions: CMVideoDimensions, minimumDimensions: CMVideoDimensions?, movieURL: URL?, captureZoomFactor: CGFloat, tryExperimentalSilencing: Bool, onCallbackUpdate: @escaping (String) -> Void, onResolved: @escaping (CMVideoDimensions) -> Void, onPhoto: @escaping (Result<CapturedPhoto, Error>) -> Void, onComplete: @escaping (Error?) -> Void) {
        self.requestedDimensions = requestedDimensions
        self.minimumDimensions = minimumDimensions
        self.movieURL = movieURL
        self.captureZoomFactor = captureZoomFactor
        self.tryExperimentalSilencing = tryExperimentalSilencing
        self.onCallbackUpdate = onCallbackUpdate
        self.onResolved = onResolved
        self.onPhoto = onPhoto
        self.onComplete = onComplete
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willBeginCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        guard minimumDimensions != nil || tryExperimentalSilencing else { return }
        // This callback reports a submitted request; AVFoundation has no per-request cancel API.
        print("[CameraCapture] resolved \(resolutionDescription(resolvedSettings.photoDimensions)); zoom=\(captureZoomFactor)")
        onResolved(resolvedSettings.photoDimensions)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        if tryExperimentalSilencing, willCaptureStatus == nil {
            // Intentionally synchronous on AVFoundation's delegate queue, matching the experiment.
            willCaptureStatus = ExperimentalShutterSilencer.attempt(event: "willCapturePhotoFor")
            onCallbackUpdate(callbackStatusSummary)
        }
        captureDate = Date()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        if tryExperimentalSilencing, didCaptureStatus == nil {
            didCaptureStatus = ExperimentalShutterSilencer.attempt(event: "didCapturePhotoFor")
            onCallbackUpdate(callbackStatusSummary)
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        logDelivery(output: output, isProxy: false, error: error)
        deliver(photo, isProxy: false, error: error)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCapturingDeferredPhotoProxy proxy: AVCaptureDeferredPhotoProxy?, error: Error?) {
        logDelivery(output: output, isProxy: true, error: error)
        deliver(proxy, isProxy: true, error: error)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        // This is the final callback. Photo and movie processing may arrive in either order.
        if tryExperimentalSilencing {
            print("[CameraCapture] \(callbackStatusSummary)")
            if case .success(var photo)? = photoResult {
                if photo.isProxy {
                    let details = minimumDimensions != nil && !isZoomedCapture ? "48MP要求" : "\(zoomDescription(captureZoomFactor)) · 完成予定 \(photo.resolvedResolution)"
                    photo.callbackTestSummary = "\(callbackStatusSummary) · \(details)"
                } else {
                    photo.callbackTestSummary = "\(callbackStatusSummary) · 実画像 \(photo.resolution)"
                }
                photoResult = .success(photo)
                onCallbackUpdate(photo.callbackTestSummary ?? callbackStatusSummary)
            } else {
                onCallbackUpdate(callbackStatusSummary)
            }
        }
        if let failure = error ?? processingError ?? movieError {
            if minimumDimensions != nil || tryExperimentalSilencing {
                print("[CameraCapture] capture rejected: \(failure.localizedDescription)")
            }
            onPhoto(.failure(failure))
        } else if movieURL != nil, !didProcessMovie {
            onPhoto(.failure(CameraFailure.livePhotoTest("Live Photoの動画処理完了を確認できませんでした。写真は保存していません。")))
        } else {
            onPhoto(photoResult ?? .failure(CameraFailure.representation))
        }
        onComplete(nil)
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingLivePhotoToMovieFileAt outputFileURL: URL, duration: CMTime, photoDisplayTime: CMTime, resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        didProcessMovie = true
        if let error { movieError = error }
        else if outputFileURL.standardizedFileURL != movieURL?.standardizedFileURL {
            movieError = CameraFailure.livePhotoTest("Live Photoの一時動画を確認できませんでした。写真は保存していません。")
        }
    }

    private func deliver(_ photo: AVCapturePhoto?, isProxy: Bool, error: Error?) {
        if let error { processingError = error; return }
        if movieURL != nil, isProxy {
            print("[LivePhoto48MP] rejected deferred proxy; completed image required")
            processingError = CameraFailure.livePhotoTest("条件未達: 完成した48MP画像ではなくプロキシが返されたため、写真は保存していません。")
            return
        }
        guard let photo, let data = photo.fileDataRepresentation(),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            processingError = CameraFailure.representation
            return
        }
        let contentType = type as String
        let fileExtension = UTType(contentType)?.preferredFilenameExtension ?? "heic"
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.int32Value
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.int32Value
        let encodedDimensions = width.flatMap { w in height.map { CMVideoDimensions(width: w, height: $0) } }
        let resolved = photo.resolvedSettings.photoDimensions
        let dimensionsToValidate: CMVideoDimensions? = isProxy ? resolved : encodedDimensions
        guard let dimensionsToValidate, dimensionsToValidate.width > 0, dimensionsToValidate.height > 0 else {
            processingError = CameraFailure.livePhotoTest("画像の画素数を確認できないため、写真は保存していません。")
            return
        }
        if minimumDimensions != nil || tryExperimentalSilencing {
            print("[CameraCapture] encoded=\(encodedDimensions.map { resolutionDescription($0) } ?? "unknown"); proxy=\(isProxy); resolved=\(resolutionDescription(resolved)); zoom=\(captureZoomFactor)")
        }
        if let minimum = minimumDimensions {
            if isProxy {
                // For a deferred proxy, photoDimensions describes the future full-quality photo.
                // Its encoded proxy dimensions must not be mistaken for the finished image.
                let proxyDescription = encodedDimensions.map { resolutionDescription($0) } ?? "unknown"
                print("[CameraCapture] proxy encoded=\(proxyDescription); resolvedFinal=\(resolutionDescription(resolved)); zoom=\(captureZoomFactor); finalProcessingPending=true")
                guard isZoomedCapture || (min(resolved.width, resolved.height) >= min(minimum.width, minimum.height)
                      && max(resolved.width, resolved.height) >= max(minimum.width, minimum.height)) else {
                    processingError = CameraFailure.livePhotoTest("条件未達: 完成予定の画像は\(resolutionDescription(resolved))です。要求した\(resolutionDescription(minimum))を下回るため、保存していません。")
                    return
                }
            } else {
                guard let width, let height, width > 0, height > 0 else {
                    processingError = CameraFailure.livePhotoTest("条件未達: 実画像の画素数を読み取れないため、写真は保存していません。")
                    return
                }
                let actual = CMVideoDimensions(width: width, height: height)
                print("[CameraCapture] encoded \(resolutionDescription(actual)); zoom=\(captureZoomFactor)")
                guard isZoomedCapture || (min(width, height) >= min(minimum.width, minimum.height)
                      && max(width, height) >= max(minimum.width, minimum.height)) else {
                    processingError = CameraFailure.livePhotoTest("条件未達: 実画像は\(resolutionDescription(actual))でした。通常撮影の\(resolutionDescription(minimum))を下回るため、保存していません。")
                    return
                }
            }
        }
        let dimensions = encodedDimensions ?? resolved
        let resolution: String
        if isProxy {
            resolution = minimumDimensions != nil && !isZoomedCapture ? "48MP要求・写真アプリで仕上げ待ち" : "\(zoomDescription(captureZoomFactor)) · 完成予定 \(resolutionDescription(resolved)) · 写真アプリで仕上げ待ち"
        } else {
            resolution = (isZoomedCapture ? "\(zoomDescription(captureZoomFactor)) · " : "") + resolutionDescription(dimensions)
        }
        photoResult = .success(CapturedPhoto(data: data, isProxy: isProxy, fileExtension: fileExtension, contentType: contentType, resolution: resolution, date: captureDate, livePhotoTestResolution: movieURL == nil ? nil : resolution, requestedResolution: resolutionDescription(requestedDimensions), captureZoomFactor: captureZoomFactor, resolvedResolution: resolutionDescription(resolved)))
    }

    private func logDelivery(output: AVCapturePhotoOutput, isProxy: Bool, error: Error?) {
        guard minimumDimensions != nil || tryExperimentalSilencing else { return }
        let detail = error.map { "\(($0 as NSError).domain):\(($0 as NSError).code) \($0.localizedDescription)" } ?? "none"
        print("[CameraCapture] delivery proxy=\(isProxy); deferred=\(output.isAutoDeferredPhotoDeliveryEnabled); error=\(detail)")
    }

    private var callbackStatusSummary: String {
        let count = (willCaptureStatus == nil ? 0 : 1) + (didCaptureStatus == nil ? 0 : 1)
        return "撮影通知で消音処理を\(count)回実行"
    }

    private var isZoomedCapture: Bool { captureZoomFactor > 1.001 }
}

private func zoomDescription(_ factor: CGFloat) -> String {
    var value = String(format: "%.2f", Double(factor))
    while value.last == "0" { value.removeLast() }
    if value.last == "." { value.removeLast() }
    return "\(value)×"
}

private func sameDimensions(_ lhs: CMVideoDimensions, _ rhs: CMVideoDimensions) -> Bool {
    lhs.width == rhs.width && lhs.height == rhs.height
}

private func pixelArea(_ dimensions: CMVideoDimensions) -> Int64 {
    Int64(dimensions.width) * Int64(dimensions.height)
}

private func resolutionDescription(_ dimensions: CMVideoDimensions) -> String {
    guard dimensions.width > 0, dimensions.height > 0 else { return "確認中" }
    let megapixels = Double(pixelArea(dimensions)) / 1_000_000
    return String(format: "%.1f MP · %d × %d", megapixels, dimensions.width, dimensions.height)
}
