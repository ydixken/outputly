import Foundation
import Testing
@testable import OutputlyApp

struct RecordingStateTests {
    private let audio = URL(fileURLWithPath: "/tmp/Outputly recording.mp3")

    @Test func sendingRequiresAPreparedTranscript() {
        var state = RecordingState()
        #expect(state.audioToPrepare == nil)
        #expect(state.transcriptToSend == nil)

        state.saveRecording(audio, successful: true)
        #expect(state.audioToPrepare == audio)
        #expect(state.transcriptToSend == nil)

        state.lastRecording?.transcript = .ready("Example transcript")
        #expect(state.audioToPrepare == nil)
        #expect(state.transcriptToSend == "Example transcript")
    }

    @Test func liveCaptureCannotBeSentAfterSwitchingModes() {
        var state = RecordingState()
        state.mode = .routeLive
        state.saveRecording(audio, successful: true)
        state.mode = .sendAfterStop

        #expect(state.lastRecording?.url == audio)
        #expect(state.audioToPrepare == nil)
        #expect(state.transcriptToSend == nil)
    }

    @Test func interruptedCaptureCanBeRevealed() {
        var state = RecordingState()
        state.saveRecording(audio, successful: false)

        #expect(state.lastRecording?.url == audio)
        #expect(state.audioToPrepare == nil)
    }

    @Test func routeLiveHidesSendActionsForPreviousCapture() {
        var state = RecordingState()
        state.saveRecording(audio, successful: true)
        state.lastRecording?.transcript = .ready("Example transcript")
        state.mode = .routeLive

        #expect(state.audioToPrepare == nil)
        #expect(state.transcriptToPreview == nil)
        #expect(state.transcriptToSend == nil)
    }

    @Test func completedDeliveryKeepsThePreviewAndDisablesResending() {
        var state = RecordingState()
        state.saveRecording(audio, successful: true)
        state.lastRecording?.transcript = .sent("Example transcript")

        #expect(state.transcriptToPreview == "Example transcript")
        #expect(state.transcriptToSend == nil)
    }

    @Test func pendingWorkKeepsQuitUnavailable() {
        var state = RecordingState()
        for phase: RecordingState.Phase in [.starting, .recording, .finalizing, .preparingTranscript, .sending] {
            state.phase = phase
            #expect(!state.canQuit)
        }
        state.phase = .idle
        #expect(state.canQuit)
    }

    @Test func staleStopCannotTriggerANewRecording() {
        var state = RecordingState()
        state.phase = .recording
        #expect(state.canStopCapture)
        #expect(!state.canStartCapture)

        state.phase = .idle
        #expect(!state.canStopCapture)
        #expect(state.canStartCapture)
    }
}
