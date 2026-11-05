import AVFoundation
import Foundation

@MainActor
final class Recorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var meter: Timer?
    private var peak: Float = -160
    private var startedAt: TimeInterval?
    private(set) var url: URL?
    var onLimit: (() -> Void)?
    var onFailure: (() -> Void)?
    var level: ((Float) -> Void)?

    func start(directory: URL, beforeRecording: () -> Void = {}) async throws {
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        try Task.checkCancellation()
        guard allowed else { throw RecordError.permission }
        let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        url = file
        let audio = try AVAudioRecorder(url: file, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 32000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ])
        recorder = audio; peak = -160
        audio.delegate = self; audio.isMeteringEnabled = true
        beforeRecording()
        guard audio.record(forDuration: 300) else { cancel(); throw RecordError.start }
        startedAt = ProcessInfo.processInfo.systemUptime
        meter = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let audio = self.recorder else { return }
                audio.updateMeters()
                self.peak = max(self.peak, audio.peakPower(forChannel: 0))
                self.level?(audio.averagePower(forChannel: 0))
            }
        }
    }

    func stop() throws -> (URL, Double) {
        guard let audio = recorder, let file = url else { throw RecordError.start }
        // currentTime becomes zero after the automatic 5-minute stop.
        let elapsed = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        let duration = min(300, max(audio.currentTime, elapsed))
        audio.delegate = nil; audio.stop(); meter?.invalidate(); meter = nil
        recorder = nil; url = nil; startedAt = nil
        guard duration >= 0.4, peak > -55 else {
            try? FileManager.default.removeItem(at: file)
            throw RecordError.silence
        }
        return (file, duration)
    }

    func cancel() {
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        meter?.invalidate(); meter = nil
        if let url { try? FileManager.default.removeItem(at: url) }
        url = nil
        startedAt = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in if flag { self.onLimit?() } else { self.onFailure?() } }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in self.onFailure?() }
    }

    enum RecordError: LocalizedError {
        case permission, start, silence
        var errorDescription: String? {
            switch self {
            case .permission: return "Allow Microphone access in System Settings → Privacy & Security → Microphone."
            case .start: return "Could not start the microphone."
            case .silence: return "No speech detected. Audio was deleted without sending."
            }
        }
    }
}
