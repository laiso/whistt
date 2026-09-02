import AppKit

enum SoundFeedback {
    private static let recordingStartedSound = NSSound(named: NSSound.Name("Tink"))

    static func playRecordingStarted() {
        if let sound = recordingStartedSound {
            sound.stop()
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}
