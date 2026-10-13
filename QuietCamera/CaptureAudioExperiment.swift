import AVFAudio
import Foundation
import OSLog

/// Opt-in experiment only. Readiness proves audio input is running, not shutter silence.
/// All control methods and callbacks use the supplied camera queue. Audio samples
/// are discarded in the tap: they are never copied, retained, written, or sent.
final class CaptureAudioExperiment: @unchecked Sendable {
    var onInterruption: (() -> Void)?

    private let queue: DispatchQueue
    private let session = AVAudioSession.sharedInstance()
    private var generation: UInt64 = 0
    private var attempt: Attempt?
    private static let logger = Logger(subsystem: "QuietCamera", category: "AudioExperiment")

    init(queue: DispatchQueue) { self.queue = queue }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        guard attempt == nil else {
            completion(.failure(ExperimentError.alreadyRunning))
            return
        }
        generation &+= 1
        let token = generation
        let current = Attempt(session: session, completion: completion)
        attempt = current

        do {
            try session.setCategory(.record, mode: .default, options: [])
            try session.setAllowHapticsAndSystemSoundsDuringRecording(false)
            try session.setActive(true)
            guard session.isInputAvailable, !session.currentRoute.inputs.isEmpty else {
                throw ExperimentError.inputUnavailable
            }

            let input = current.engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw ExperimentError.inputUnavailable
            }
            let firstBuffer = FirstBufferSignal()
            let callbackQueue = queue
            input.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
                // Only one small dispatch per attempt; never capture the audio buffer.
                guard buffer.frameLength > 0, firstBuffer.claim() else { return }
                callbackQueue.async { [weak self] in self?.becameReady(token: token) }
            }
            current.tapInstalled = true
            current.engine.prepare()
            try current.engine.start()
            observeChanges(for: current, token: token)

            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.generation == token,
                      self.attempt?.completion != nil else { return }
                self.finish(error: ExperimentError.readinessTimeout, notifyInterruption: false)
            }
        } catch {
            finish(error: error, notifyInterruption: false)
        }
    }

    func stop() {
        dispatchPrecondition(condition: .onQueue(queue))
        finish(error: ExperimentError.cancelled, notifyInterruption: false)
    }

    private func becameReady(token: UInt64) {
        guard generation == token, let current = attempt,
              let completion = current.completion else { return }
        guard current.engine.isRunning, session.isInputAvailable,
              !session.currentRoute.inputs.isEmpty else {
            finish(error: ExperimentError.inputUnavailable, notifyInterruption: false)
            return
        }
        current.completion = nil
        Self.logger.notice("Audio input received; submitting the full-resolution photo experiment. This does not confirm silence.")
        // A missing camera completion must not leave the microphone running indefinitely.
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.generation == token, self.attempt != nil else { return }
            self.finish(error: ExperimentError.activeTimeout, notifyInterruption: true)
        }
        completion(.success(()))
    }

    private func observeChanges(for current: Attempt, token: UInt64) {
        let center = NotificationCenter.default
        let callbackQueue = queue
        current.observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: nil
        ) { [weak self] notification in
            let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            guard type == AVAudioSession.InterruptionType.began.rawValue else { return }
            callbackQueue.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.finish(error: ExperimentError.interrupted, notifyInterruption: true)
            }
        })
        for name in [AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            current.observers.append(center.addObserver(forName: name, object: session, queue: nil) { [weak self] _ in
                callbackQueue.async { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.finish(error: ExperimentError.interrupted, notifyInterruption: true)
                }
            })
        }
        for (name, object) in [(AVAudioSession.routeChangeNotification, session as AnyObject),
                               (Notification.Name.AVAudioEngineConfigurationChange, current.engine as AnyObject)] {
            current.observers.append(center.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                callbackQueue.async { [weak self] in
                    guard let self, self.generation == token, let active = self.attempt else { return }
                    if !active.engine.isRunning || !self.session.isInputAvailable || self.session.currentRoute.inputs.isEmpty {
                        self.finish(error: ExperimentError.inputUnavailable, notifyInterruption: true)
                    }
                }
            })
        }
    }

    private func finish(error: Error, notifyInterruption: Bool) {
        guard let current = attempt else { return }
        attempt = nil
        generation &+= 1 // Late tap, notification, and timeout callbacks cannot affect a later attempt.
        let completion = current.completion
        current.completion = nil
        Self.release(current, session: session)
        if let completion {
            completion(.failure(error))
        } else if notifyInterruption {
            onInterruption?()
        }
    }

    private static func release(_ current: Attempt, session: AVAudioSession) {
        current.observers.forEach(NotificationCenter.default.removeObserver)
        current.observers.removeAll()
        current.engine.stop()
        logger.notice("Audio input experiment stopped. No audio was saved.")
        if current.tapInstalled {
            current.engine.inputNode.removeTap(onBus: 0)
            current.tapInstalled = false
        }
        do { try session.setActive(false, options: .notifyOthersOnDeactivation) }
        catch { logger.error("Could not deactivate audio experiment: \(error.localizedDescription, privacy: .public)") }
        do {
            try session.setCategory(current.category, mode: current.mode, options: current.options)
            try session.setAllowHapticsAndSystemSoundsDuringRecording(current.allowSystemSounds)
        } catch {
            logger.error("Could not restore audio configuration: \(error.localizedDescription, privacy: .public)")
        }
    }

    deinit {
        // Normal owners call stop(). If an owner disappears early, finish cleanup
        // and any pending completion on the same queue without retaining self.
        if let current = attempt {
            let audioSession = session
            queue.async {
                Self.release(current, session: audioSession)
                current.completion?(.failure(ExperimentError.cancelled))
                current.completion = nil
            }
        }
    }

    private final class Attempt: @unchecked Sendable {
        let engine = AVAudioEngine()
        let category: AVAudioSession.Category
        let mode: AVAudioSession.Mode
        let options: AVAudioSession.CategoryOptions
        let allowSystemSounds: Bool
        var completion: ((Result<Void, Error>) -> Void)?
        var tapInstalled = false
        var observers: [NSObjectProtocol] = []

        init(session: AVAudioSession, completion: @escaping (Result<Void, Error>) -> Void) {
            category = session.category
            mode = session.mode
            options = session.categoryOptions
            allowSystemSounds = session.allowHapticsAndSystemSoundsDuringRecording
            self.completion = completion
        }
    }

    /// A nonblocking one-shot gate; audio callbacks never wait for a lock.
    private final class FirstBufferSignal: @unchecked Sendable {
        private let lock = NSLock()
        private var signalled = false
        func claim() -> Bool {
            guard lock.try() else { return false }
            defer { lock.unlock() }
            guard !signalled else { return false }
            signalled = true
            return true
        }
    }

    private enum ExperimentError: LocalizedError {
        case alreadyRunning, inputUnavailable, readinessTimeout, activeTimeout, interrupted, cancelled
        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "音声入力の実験はすでに実行中です。"
            case .inputUnavailable: return "実験用の音声入力を使用できません。"
            case .readinessTimeout: return "音声入力を確認できませんでした。もう一度お試しください。"
            case .activeTimeout: return "実験用の音声入力を時間制限で停止しました。"
            case .interrupted: return "実験用の音声入力が中断されました。"
            case .cancelled: return "実験用の音声入力を停止しました。"
            }
        }
    }
}
