import Foundation

struct RecordingState {
    enum Mode: String, CaseIterable {
        case sendAfterStop = "Send after Stop"
        case routeLive = "Route Live"
    }

    enum Phase {
        case idle, starting, recording, finalizing, preparingTranscript, sending
    }

    enum Transcript {
        case unavailable, unprepared, ready(String), sent(String)
    }

    struct Recording {
        let url: URL
        var transcript: Transcript
    }

    var mode: Mode = .sendAfterStop
    var phase: Phase = .idle
    var lastRecording: Recording?

    var canStartCapture: Bool { phase == .idle }
    var canStopCapture: Bool { phase == .recording }
    var canQuit: Bool { phase == .idle }

    var audioToPrepare: URL? {
        guard phase == .idle, mode == .sendAfterStop,
              let lastRecording, case .unprepared = lastRecording.transcript else { return nil }
        return lastRecording.url
    }

    var transcriptToPreview: String? {
        guard phase == .idle, mode == .sendAfterStop else { return nil }
        switch lastRecording?.transcript {
        case .ready(let text), .sent(let text): return text
        default: return nil
        }
    }

    var transcriptToSend: String? {
        guard phase == .idle, mode == .sendAfterStop,
              case .ready(let text) = lastRecording?.transcript else { return nil }
        return text
    }

    mutating func saveRecording(_ url: URL, successful: Bool) {
        let transcript: Transcript = successful && mode == .sendAfterStop ? .unprepared : .unavailable
        lastRecording = Recording(url: url, transcript: transcript)
    }
}
