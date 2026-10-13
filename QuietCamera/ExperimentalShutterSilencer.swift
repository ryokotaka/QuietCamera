import AudioToolbox
import OSLog

/// Automatic fallback, isolated from the supported AVFoundation suppression path.
/// The function is public, but using the literal ID 1108 for camera muting is NOT
/// an Apple-documented contract. A successful return code does not prove silence.
enum ExperimentalShutterSilencer {
    private static let logger = Logger(subsystem: "QuietCamera", category: "ShutterExperiment")

    static func attempt(event: String) -> OSStatus {
        let status = AudioServicesDisposeSystemSoundID(SystemSoundID(1108))
        logger.notice("\(event, privacy: .public): automatic disposal of ID 1108 returned \(status). This does not confirm shutter silence.")
        return status
    }
}
