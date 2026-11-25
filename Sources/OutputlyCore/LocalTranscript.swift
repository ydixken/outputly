import AVFoundation
import Foundation
import Speech

public enum LocalTranscript {
    public static func transcribe(_ audio: URL) async throws -> String {
        guard let file = try? AVAudioFile(forReading: audio), file.length > 0 else {
            throw TranscriptError.unreadableRecording
        }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current) else {
            throw TranscriptError.speechUnavailable
        }
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        } catch {
            throw TranscriptError.speechAssetsUnavailable
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        async let transcript = transcriber.results.reduce(into: "") { text, result in
            text.append(contentsOf: result.text.characters)
        }
        do {
            guard let lastSample = try await analyzer.analyzeSequence(from: file) else {
                throw TranscriptError.noSpeech
            }
            try await analyzer.finalizeAndFinish(through: lastSample)
            let text = try await transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw TranscriptError.noSpeech
            }
            return text
        } catch {
            await analyzer.cancelAndFinishNow()
            throw (error as? TranscriptError) ?? .speechFailed
        }
    }
}

private enum TranscriptError: LocalizedError {
    case unreadableRecording
    case speechUnavailable
    case speechAssetsUnavailable
    case speechFailed
    case noSpeech

    var errorDescription: String? {
        switch self {
        case .unreadableRecording:
            "Could not read the recording for transcription."
        case .speechUnavailable:
            "On-device speech recognition is unavailable for this Mac or its current language."
        case .speechAssetsUnavailable:
            "Could not prepare the on-device speech model. Check your internet connection and try again."
        case .speechFailed:
            "On-device transcription failed. The MP3 is still available."
        case .noSpeech:
            "No speech was recognized in this recording."
        }
    }
}
