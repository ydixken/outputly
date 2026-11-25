import AppKit
import OutputlyCore

@main
enum OutputlyApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let controller = AppController()
        application.delegate = controller
        withExtendedLifetime(controller) {
            application.run()
        }
    }
}

@MainActor
private final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let capture = CaptureSession()
    private let settings = UserDefaults.standard
    private var state = RecordingState() {
        didSet { updateStatusItem() }
    }
    private var inputID: String?
    private var destination: Destination = .codex
    private var activeRecording: RecordingFiles?
    private var captureFailure: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        inputID = settings.string(forKey: "microphone")
        if let mode = settings.string(forKey: "mode").flatMap(RecordingState.Mode.init(rawValue:)) {
            state.mode = mode
        }
        if let savedDestination = settings.string(forKey: "destination").flatMap(Destination.init(rawValue:)) {
            destination = savedDestination
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        updateStatusItem()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state.canQuit ? .terminateNow : .terminateCancel
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let idle = state.canStartCapture
        let recording = state.canStopCapture
        var items = [
            recording
                ? command("Stop Recording", #selector(requestStopRecording))
                : command("Start Recording", #selector(requestStartRecording), enabled: idle),
        ]
        let activity: String?
        switch state.phase {
        case .idle, .recording: activity = nil
        case .starting: activity = "Starting recording…"
        case .finalizing: activity = "Saving recording…"
        case .preparingTranscript: activity = "Preparing transcript…"
        case .sending: activity = "Sending transcript to \(destination.rawValue)…"
        }
        if let activity {
            items.append(command(activity, nil, enabled: false))
        }

        items += [
            .separator(),
            submenu("Microphone", items: idle ? microphones() : []),
            submenu("Mode", items: RecordingState.Mode.allCases.map { mode in
                command(mode.rawValue, #selector(selectMode(_:)), value: mode.rawValue, checked: state.mode == mode)
            }),
            submenu("Destination", items: Destination.allCases.map { option in
                command(option.rawValue, #selector(selectDestination(_:)), value: option.rawValue,
                    checked: destination == option)
            }),
            .separator(),
        ]

        switch state.mode {
        case .sendAfterStop:
            if state.transcriptToPreview != nil {
                items.append(command("Preview Transcript…", #selector(previewTranscript)))
            } else if state.audioToPrepare != nil {
                items.append(command("Prepare Transcript…", #selector(retryTranscript)))
            }
            items.append(command("Send Transcript to \(destination.rawValue)", #selector(sendTranscript),
                enabled: state.transcriptToSend != nil))
        case .routeLive:
            items.append(command("Live Routing Instructions…", #selector(showLiveInstructions), enabled: idle || recording))
        }
        items += [
            command("Reveal Last Recording", #selector(revealLastRecording), enabled: idle && state.lastRecording != nil),
            .separator(),
            command("Quit Outputly", #selector(quit), enabled: state.canQuit),
        ]
        menu.items = items
    }

    private func microphones() -> [NSMenuItem] {
        let action = #selector(selectMicrophone(_:))
        var items = [command("System Default", action, checked: inputID == nil)]
        do {
            let inputs = try CaptureSession.inputs()
            items += inputs.map { input in
                command(input.name, action, value: input.id, checked: inputID == input.id)
            }
            if let inputID, !inputs.contains(where: { $0.id == inputID }) {
                items.append(command("Selected Microphone Unavailable", nil, enabled: false, checked: true))
            }
        } catch {
            items.append(command("Microphone List Unavailable", nil, enabled: false))
        }
        return items
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = command(title, nil, enabled: state.phase == .idle)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.items = items
        item.submenu = menu
        return item
    }

    private func command(
        _ title: String, _ action: Selector?, enabled: Bool = true, value: String? = nil, checked: Bool = false
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.representedObject = value
        item.state = checked ? .on : .off
        return item
    }

    private func updateStatusItem() {
        let recording = state.phase == .recording
        let label = recording ? "Outputly is recording" : "Outputly"
        statusItem.button?.image = NSImage(systemSymbolName: recording ? "mic.fill" : "mic", accessibilityDescription: label)
        statusItem.button?.contentTintColor = recording ? .systemRed : nil
        statusItem.button?.toolTip = label
        statusItem.button?.setAccessibilityLabel(label)
    }

    @objc private func selectMicrophone(_ item: NSMenuItem) {
        guard state.phase == .idle else { return }
        inputID = item.representedObject as? String
        settings.set(inputID, forKey: "microphone")
    }

    @objc private func selectMode(_ item: NSMenuItem) {
        guard state.phase == .idle, let value = item.representedObject as? String,
              let mode = RecordingState.Mode(rawValue: value) else { return }
        state.mode = mode
        settings.set(value, forKey: "mode")
    }

    @objc private func selectDestination(_ item: NSMenuItem) {
        guard state.phase == .idle, let value = item.representedObject as? String,
              let option = Destination(rawValue: value) else { return }
        destination = option
        settings.set(value, forKey: "destination")
    }

    @objc private func requestStartRecording() {
        guard state.canStartCapture else { return }
        state.phase = .starting
        Task { await startRecording() }
    }

    @objc private func requestStopRecording() {
        guard state.canStopCapture else { return }
        Task { await finishRecording() }
    }

    private func startRecording() async {
        do {
            let files = try await Task.detached {
                try MP3Export.checkAvailability()
                return try RecordingFiles.create()
            }.value
            activeRecording = files
            try await capture.start(inputID: inputID, live: state.mode == .routeLive, recordingURL: files.pcmURL) {
                [weak self] message in
                Task { @MainActor in
                    self?.captureDidFail(message, for: files.pcmURL)
                }
            }
            state.phase = .recording
            if captureFailure != nil {
                await finishRecording()
            }
        } catch {
            let source = activeRecording.flatMap(recoverSource)
            resetCapture()
            showDialog("Couldn’t Start Recording", message: error.localizedDescription, recording: source, warning: true)
        }
    }

    private func captureDidFail(_ message: String, for url: URL) {
        guard activeRecording?.pcmURL == url, captureFailure == nil else { return }
        captureFailure = message
        if state.canStopCapture {
            Task { await finishRecording() }
        }
    }

    private func finishRecording() async {
        guard state.canStopCapture, let files = activeRecording else { return }
        state.phase = .finalizing
        do {
            try await capture.stop()
        } catch {
            if let failure = error as? AudioCaptureError, !failure.recordingFinalized {
                let source = recoverSource(files)
                resetCapture()
                showDialog("Couldn’t Finalize Recording", message: failure.localizedDescription,
                    recording: source, warning: true)
                return
            }
            captureFailure = captureFailure ?? error.localizedDescription
        }

        do {
            try await MP3Export.encode(files)
            let failure = captureFailure
            state.saveRecording(files.mp3URL, successful: failure == nil)
            resetCapture()
            if let failure {
                showDialog("Recording Interrupted", message: "\(failure) The partial MP3 was saved.",
                    recording: files.mp3URL, warning: true)
            } else {
                prepareTranscript(showPreview: false)
            }
        } catch {
            let source = recoverSource(files)
            let details = [captureFailure, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
            resetCapture()
            showDialog("Couldn’t Save MP3", message: details, recording: source, warning: true)
        }
    }

    private func recoverSource(_ files: RecordingFiles) -> URL? {
        guard FileManager.default.fileExists(atPath: files.pcmURL.path) else {
            files.removeEmptyWorkspace()
            return nil
        }
        state.saveRecording(files.pcmURL, successful: false)
        return files.pcmURL
    }

    private func resetCapture() {
        activeRecording = nil
        captureFailure = nil
        state.phase = .idle
    }

    @objc private func retryTranscript() {
        prepareTranscript(showPreview: true)
    }

    private func prepareTranscript(showPreview: Bool) {
        guard let audio = state.audioToPrepare else { return }
        state.phase = .preparingTranscript
        Task {
            do {
                let transcript = try await LocalTranscript.transcribe(audio)
                state.lastRecording?.transcript = .ready(transcript)
                state.phase = .idle
                if showPreview {
                    previewTranscript()
                }
            } catch {
                state.phase = .idle
                showDialog("Couldn’t Prepare Transcript", message: error.localizedDescription, warning: true)
            }
        }
    }

    @objc private func previewTranscript() {
        guard let transcript = state.transcriptToPreview else { return }
        showDialog("Transcript Preview", content: transcript)
    }

    @objc private func sendTranscript() {
        guard let transcript = state.transcriptToSend else { return }
        let target = destination
        state.phase = .sending
        Task {
            do {
                let result = try await TranscriptDelivery.send(transcript, to: target)
                state.lastRecording?.transcript = .sent(transcript)
                state.phase = .idle
                showDialog("Transcript Sent to \(target.rawValue)", content: result)
            } catch {
                state.phase = .idle
                showDialog("Couldn’t Send to \(target.rawValue)", message: error.localizedDescription, warning: true)
            }
        }
    }

    @objc private func showLiveInstructions() {
        guard state.mode == .routeLive, state.canStartCapture || state.canStopCapture else { return }
        let dictation: String
        switch destination {
        case .codex:
            dictation = "Start dictation in Codex. Spoken replies can feed back because Outputly routes system playback to VB-Cable."
        case .claudeCode:
            dictation = "In Claude Code, enable /voice if needed and start dictating."
        }
        showDialog("Route Live to \(destination.rawValue)", message: """
            Choose your physical microphone in Outputly. Select VB-Cable as the input in your voice client, or in \
            System Settings > Sound > Input if it uses the system default. Choose Start Recording in Outputly.

            \(dictation)
            """)
    }

    @objc private func revealLastRecording() {
        guard state.phase == .idle, let url = state.lastRecording?.url else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            showDialog("Recording Unavailable", message: "The recording has been moved or deleted.", warning: true)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func quit() {
        guard state.canQuit else { return }
        NSApp.terminate(nil)
    }

    private func showDialog(
        _ title: String, message: String = "", content: String? = nil, recording: URL? = nil, warning: Bool = false
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = warning ? .warning : .informational
        if let content {
            let scroll = NSTextView.scrollablePlainDocumentContentTextView()
            scroll.frame.size = NSSize(width: 440, height: 200)
            scroll.hasVerticalScroller = true
            if let textView = scroll.documentView as? NSTextView {
                textView.string = content
                textView.font = .systemFont(ofSize: NSFont.systemFontSize)
                textView.isEditable = false
                textView.setAccessibilityLabel(title)
            }
            alert.accessoryView = scroll
        }
        alert.addButton(withTitle: "OK")
        if recording != nil {
            alert.addButton(withTitle: "Reveal Recording")
        }
        NSApp.activate()
        if alert.runModal() == .alertSecondButtonReturn, let recording {
            NSWorkspace.shared.activateFileViewerSelecting([recording])
        }
    }
}
