import AudioToolbox
import AVFoundation
import CoreAudio
import Foundation

public struct AudioInput: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
}

@MainActor
public final class CaptureSession {
    private enum Phase { case idle, starting, recording, stopping }

    private let worker = CaptureWorker()
    private var phase = Phase.idle
    private var monitor: Task<Void, Never>?
    private var stopping: Task<Void, Error>?
    private var lastFailure: AudioCaptureError?

    public init() {}

    deinit {
        monitor?.cancel()
        let worker = worker
        Task { try? await worker.stop() }
    }

    public static func inputs() throws -> [AudioInput] {
        try CaptureDevice.all().filter(\.isMicrophone)
            .map { AudioInput(id: $0.uid, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func start(
        inputID: String?,
        live: Bool,
        recordingURL: URL,
        onFailure: @escaping @Sendable (String) -> Void
    ) async throws {
        guard phase == .idle else { throw AudioCaptureError("An audio session is already active.") }
        phase = .starting
        lastFailure = nil

        do {
            try await worker.prepare(inputID: inputID, live: live)
            let allowed: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: allowed = true
            case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
            default: allowed = false
            }
            guard allowed else {
                throw AudioCaptureError("Allow Outputly in System Settings → Privacy & Security → Microphone.")
            }

            try Task.checkCancellation()
            try await worker.start(recordingURL: recordingURL)
            let deadline = ContinuousClock.now + .seconds(10)
            while try await worker.frames() == 0 {
                guard ContinuousClock.now < deadline else {
                    throw AudioCaptureError("No audio frames arrived. Check the selected microphone and allow Outputly in System Settings → Privacy & Security → Screen & System Audio Recording.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
            phase = .recording
            watch(onFailure)
        } catch {
            try? await worker.stop()
            phase = .idle
            throw error
        }
    }

    public func stop() async throws {
        switch phase {
        case .idle:
            if let lastFailure { throw lastFailure }
            return
        case .starting:
            throw AudioCaptureError("An audio session is still starting.")
        case .recording:
            monitor?.cancel()
        case .stopping:
            break
        }
        try await finish()
    }

    private func finish(_ interruption: AudioCaptureError? = nil) async throws {
        if let stopping { return try await stopping.value }

        phase = .stopping
        let worker = worker
        let task = Task {
            do {
                try await worker.stop()
            } catch let failure as AudioCaptureError {
                throw AudioCaptureError(
                    interruption?.message ?? failure.message,
                    recordingFinalized: failure.recordingFinalized
                )
            }
            if let interruption { throw interruption }
        }
        stopping = task
        defer {
            phase = .idle
            stopping = nil
            monitor = nil
        }
        do {
            try await task.value
        } catch {
            let failure = (error as? AudioCaptureError) ?? AudioCaptureError(error.localizedDescription)
            lastFailure = failure
            throw failure
        }
    }

    private func watch(_ onFailure: @escaping @Sendable (String) -> Void) {
        let worker = worker
        monitor = Task { [weak self] in
            var latestFrames: UInt64 = 0
            var latestProgress = ContinuousClock.now
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(250))
                    let frames = try await worker.frames()
                    if frames != latestFrames {
                        latestProgress = ContinuousClock.now
                        latestFrames = frames
                    } else if ContinuousClock.now - latestProgress >= .seconds(2) {
                        throw AudioCaptureError("Audio capture stopped receiving frames. Check the microphone and VB-Cable connection.")
                    }
                }
            } catch {
                guard !Task.isCancelled, let self, phase == .recording else { return }
                let failure = (error as? AudioCaptureError) ?? AudioCaptureError(error.localizedDescription)
                try? await finish(failure)
                onFailure(failure.message)
            }
        }
    }
}

struct CaptureDevice {
    let objectID: AudioObjectID
    let uid: String
    let name: String
    let transport: UInt32
    let inputs: [UInt32]
    let outputs: [UInt32]
    let modelUID: String

    var isMicrophone: Bool {
        inputs.contains(where: { $0 > 0 }) && !isCableDriver && ![
            kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeAutoAggregate, kAudioDeviceTransportTypeVirtual
        ].contains(transport)
    }

    private var isCableDriver: Bool { modelUID.hasPrefix("com.vbaudio.vbcable.model:") }

    static func all() throws -> [CaptureDevice] {
        try AudioHardwareSystem.shared.devices.compactMap { device in
            guard (try? device.isAlive) == true else { return nil }
            return try? CaptureDevice(
                objectID: device.id, uid: device.uid, name: device.name, transport: device.transportType,
                inputs: device.inputStreamConfiguration.map(\.mNumberChannels),
                outputs: device.outputStreamConfiguration.map(\.mNumberChannels), modelUID: device.modelUID
            )
        }
    }

    static func microphone(in devices: [CaptureDevice], requestedUID: String?, defaultID: AudioObjectID?) -> CaptureDevice? {
        devices.first { device in
            device.isMicrophone && (requestedUID.map { $0 == device.uid } ?? (defaultID == device.objectID))
        }
    }

    static func cable(in devices: [CaptureDevice]) -> CaptureDevice? {
        let cables = devices.filter { $0.isCableDriver && $0.inputs == [2] && $0.outputs == [2] }
        return cables.count == 1 ? cables[0] : nil
    }
}

private actor CaptureWorker {
    private var microphone: CaptureDevice?
    private var cable: CaptureDevice?
    private var run: CaptureRun?

    func prepare(inputID: String?, live: Bool) throws {
        let devices = try CaptureDevice.all()
        let defaultID = inputID == nil ? try AudioHardwareSystem.shared.defaultInputDevice?.id : nil
        guard let microphone = CaptureDevice.microphone(in: devices, requestedUID: inputID, defaultID: defaultID) else {
            throw AudioCaptureError(inputID == nil
                ? "System Default is not a physical microphone. Choose a physical microphone in Outputly."
                : "The pinned microphone is unavailable. Reconnect it or choose another microphone.")
        }
        let cable = live ? CaptureDevice.cable(in: devices) : nil
        guard !live || cable != nil else {
            throw AudioCaptureError("Live mode requires one available VB-Cable with stereo input and output.")
        }

        self.microphone = microphone
        self.cable = cable
    }

    func start(recordingURL: URL) throws {
        guard let microphone else { throw AudioCaptureError("No microphone was prepared for this session.") }
        let run = CaptureRun(microphone: microphone, cable: cable)
        do {
            try run.start(recordingURL: recordingURL)
            self.run = run
        } catch {
            try? run.finish()
            throw error
        }
    }

    func frames() throws -> UInt64 {
        guard let run else { return 0 }
        return try run.frames()
    }

    func stop() throws {
        let activeRun = run
        run = nil
        microphone = nil
        cable = nil
        try activeRun?.finish()
    }
}

private final class CaptureRun {
    private let microphone: CaptureDevice
    private let cable: CaptureDevice?
    private let system = AudioHardwareSystem.shared

    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?
    private var proc: AudioDeviceIOProcID?
    private var io: CaptureIO?
    private var layout: CaptureLayout?
    private var interruption: AudioCaptureError?
    private var sampleRate = 0.0

    init(microphone: CaptureDevice, cable: CaptureDevice?) {
        self.microphone = microphone
        self.cable = cable
    }

    func start(recordingURL: URL) throws {
        guard let process = try system.process(for: getpid()) else {
            throw AudioCaptureError("Core Audio could not identify Outputly for feedback exclusion.")
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [process.id])
        description.name = "Outputly System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        if let bundleID = Bundle.main.bundleIdentifier { description.bundleIDs = [bundleID] }

        guard let tap = try system.makeProcessTap(description: description) else {
            throw AudioCaptureError("Core Audio could not create the system audio tap.")
        }
        self.tap = tap

        var subdevices: [[String: Any]] = [[kAudioSubDeviceUIDKey: microphone.uid]]
        if let cable {
            subdevices.append([kAudioSubDeviceUIDKey: cable.uid, kAudioSubDeviceDriftCompensationKey: true])
        }
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Outputly Capture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceSubDeviceListKey: subdevices,
            kAudioAggregateDeviceMainSubDeviceKey: microphone.uid,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: try tap.uid, kAudioSubTapDriftCompensationKey: true]]
        ]
        guard let aggregate = try system.makeAggregateDevice(description: composition) else {
            throw AudioCaptureError("Core Audio could not combine the selected audio devices.")
        }
        self.aggregate = aggregate

        let microphoneDevice = AudioHardwareDevice(id: microphone.objectID)
        let layout = try CaptureLayout(
            microphoneInputs: microphone.inputs, microphoneOutputs: microphone.outputs,
            preferredMicrophoneChannels: try? microphoneDevice.preferredInputChannelsForStereo, live: cable != nil
        )
        self.layout = layout
        sampleRate = try aggregate.nominalSampleRate
        try validate(aggregate, layout: layout)
        let maxFrames = try aggregate.usesVariableBufferFrameSizes
            ? try aggregate.largestVariableBufferFrameSize : try aggregate.bufferFrameSize
        guard (1...65_536).contains(maxFrames), sampleRate.isFinite, sampleRate > 0 else {
            throw AudioCaptureError("The selected audio devices reported an unsupported buffer size or sample rate.")
        }

        let io = try CaptureIO(layout: layout, capacity: maxFrames, sampleRate: sampleRate, url: recordingURL)
        self.io = io
        var proc: AudioDeviceIOProcID?
        try AudioCaptureError.check(
            AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate.id, nil) { _, input, _, output, _ in
                io.process(input: input, output: output)
            },
            "Could not register audio capture"
        )
        guard let proc else { throw AudioCaptureError("Core Audio did not register audio capture.") }
        self.proc = proc

        // Registering IO prompts for system audio access, but HAL can report success after denial.
        do {
            try tap.setDescription(tap.description)
        } catch {
            throw AudioCaptureError("Allow Outputly in System Settings → Privacy & Security → Screen & System Audio Recording.")
        }
        try useStreams(layout.usedInputs, aggregate: aggregate.id, proc: proc, scope: kAudioObjectPropertyScopeInput)
        try useStreams(layout.usedOutputs, aggregate: aggregate.id, proc: proc, scope: kAudioObjectPropertyScopeOutput)
        try AudioCaptureError.check(
            AudioDeviceStart(aggregate.id, proc),
            "Could not start audio capture. Check microphone and system audio permissions"
        )
    }

    func frames() throws -> UInt64 {
        if let interruption { throw interruption }
        if let failure = io?.failure {
            interruption = failure
            throw failure
        }
        do {
            guard let aggregate, let layout, try aggregate.isAlive, try aggregate.nominalSampleRate == sampleRate else {
                throw AudioCaptureError("An audio device disconnected or changed its sample rate.")
            }
            try validate(aggregate, layout: layout)
            return io?.frames ?? 0
        } catch {
            let failure = (error as? AudioCaptureError) ?? AudioCaptureError("The selected audio devices are unavailable.")
            interruption = failure
            throw failure
        }
    }

    func finish() throws {
        io?.deactivate()
        var cleanupError: AudioCaptureError?
        if let aggregate, let proc {
            let stopStatus = AudioDeviceStop(aggregate.id, proc)
            if stopStatus != noErr {
                cleanupError = AudioCaptureError("Core Audio could not stop the audio device (\(stopStatus)).")
            }
            let status = AudioDeviceDestroyIOProcID(aggregate.id, proc)
            if status != noErr, cleanupError == nil {
                cleanupError = AudioCaptureError("Core Audio could not release the audio callback (\(status)).")
            }
        }

        if let aggregate {
            do { try system.destroyAggregateDevice(aggregate) } catch {
                if cleanupError == nil { cleanupError = AudioCaptureError("Could not release the private audio device (\(error.localizedDescription)).") }
            }
        }
        if let tap {
            do { try system.destroyProcessTap(tap) } catch {
                if cleanupError == nil { cleanupError = AudioCaptureError("Could not release the system audio tap (\(error.localizedDescription)).") }
            }
        }

        var recordingFinalized = true
        if let io {
            let deadline = ContinuousClock.now + .seconds(1)
            while io.isWriting, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.001)
            }
            if io.isWriting {
                recordingFinalized = false
                cleanupError = AudioCaptureError("The audio callback is still finishing. The original recording was preserved.")
            } else {
                let status = io.close()
                if status != noErr {
                    recordingFinalized = false
                    cleanupError = AudioCaptureError("Could not finalize the local audio recording (Core Audio \(status)).")
                }
            }
        }

        if let failure = interruption ?? io?.failure ?? cleanupError {
            throw AudioCaptureError(failure.message, recordingFinalized: recordingFinalized)
        }
    }

    private func validate(_ aggregate: AudioHardwareAggregateDevice, layout: CaptureLayout) throws {
        let inputs = try aggregate.inputStreamConfiguration.map(\.mNumberChannels)
        let outputs = try aggregate.outputStreamConfiguration.map(\.mNumberChannels)
        let uids = try aggregate.activeSubdevices.map { try $0.uid }
        guard inputs == layout.inputChannels, outputs == layout.outputChannels,
              uids == [microphone.uid] + (cable.map { [$0.uid] } ?? []),
              try aggregate.clockSource?.id == microphone.objectID
        else {
            throw AudioCaptureError("The microphone, system audio tap, or VB-Cable reported an unexpected channel layout.")
        }

        let streams = try aggregate.streams
        try checkStreams(streams.filter { try $0.direction == .input }, channels: inputs)
        try checkStreams(streams.filter { try $0.direction == .output }, channels: outputs)
    }

    private func checkStreams(_ streams: [AudioHardwareStream], channels: [UInt32]) throws {
        guard streams.count == channels.count else {
            throw AudioCaptureError("Core Audio reported an unexpected number of audio streams.")
        }
        var startingChannel = 1
        for (stream, channels) in zip(streams, channels) {
            let format = try stream.virtualFormat
            let frameBytes = Int(channels) * MemoryLayout<Float>.size
            guard try stream.startingChannel == startingChannel,
                  format.mFormatID == kAudioFormatLinearPCM,
                  format.mFormatFlags == kAudioFormatFlagsNativeFloatPacked,
                  format.mChannelsPerFrame == channels,
                  format.mBitsPerChannel == 32,
                  format.mFramesPerPacket == 1,
                  format.mBytesPerFrame == frameBytes,
                  format.mBytesPerPacket == frameBytes
            else { throw AudioCaptureError("The selected audio devices do not expose supported Float32 streams.") }
            startingChannel += Int(channels)
        }
    }

    private func useStreams(
        _ streams: [Bool], aggregate: AudioObjectID, proc: AudioDeviceIOProcID, scope: AudioObjectPropertyScope
    ) throws {
        guard !streams.isEmpty, streams.contains(false) else { return }
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!
        let size = offset + streams.count * MemoryLayout<UInt32>.stride
        let data = UnsafeMutableRawPointer.allocate(
            byteCount: size, alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment
        )
        defer { data.deallocate() }
        let usage = AudioHardwareIOProcStreamUsage(
            mIOProc: unsafeBitCast(proc, to: UnsafeMutableRawPointer.self),
            mNumberStreams: UInt32(streams.count), mStreamIsOn: 0
        )
        data.storeBytes(of: usage, as: AudioHardwareIOProcStreamUsage.self)
        for (index, enabled) in streams.enumerated() {
            data.storeBytes(of: UInt32(enabled ? 1 : 0), toByteOffset: offset + index * MemoryLayout<UInt32>.stride, as: UInt32.self)
        }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIOProcStreamUsage, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
        try AudioCaptureError.check(
            AudioObjectSetPropertyData(aggregate, &address, 0, nil, UInt32(size), data),
            "Could not isolate the selected microphone and VB-Cable streams"
        )
    }
}
