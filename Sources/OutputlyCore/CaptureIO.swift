import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

struct CaptureLayout {
    private struct Channel {
        let buffer: Int
        let index: Int
    }

    let inputChannels: [UInt32]
    let outputChannels: [UInt32]
    let tapBuffer: Int
    let cableBuffer: Int?
    private let left: Channel
    private let right: Channel

    init(
        microphoneInputs: [UInt32],
        microphoneOutputs: [UInt32],
        preferredMicrophoneChannels: [UInt32]?,
        live: Bool
    ) throws {
        let channelCount = microphoneInputs.reduce(0) { $0 + Int($1) }
        guard channelCount > 0, microphoneInputs.allSatisfy({ $0 > 0 }) else {
            throw AudioCaptureError("The selected microphone has no supported input channels.")
        }

        let preferred = preferredMicrophoneChannels ?? []
        let pair = preferred.count == 2 && preferred.allSatisfy({ (1...channelCount).contains(Int($0)) })
            ? preferred.map(Int.init) : [1, min(2, channelCount)]

        func location(_ number: Int) -> Channel {
            var index = number - 1
            for (buffer, count) in microphoneInputs.enumerated() {
                if index < count { return Channel(buffer: buffer, index: index) }
                index -= Int(count)
            }
            preconditionFailure("Validated microphone channel is outside the HAL layout")
        }

        left = location(pair[0])
        right = location(pair[1])
        tapBuffer = microphoneInputs.count + (live ? 1 : 0)
        cableBuffer = live ? microphoneOutputs.count : nil
        inputChannels = microphoneInputs + (live ? [2, 2] : [2])
        outputChannels = microphoneOutputs + (live ? [2] : [])
    }

    var usedInputs: [Bool] {
        inputChannels.indices.map { $0 == left.buffer || $0 == right.buffer || $0 == tapBuffer }
    }

    var usedOutputs: [Bool] {
        outputChannels.indices.map { $0 == cableBuffer }
    }

    func mix(
        input: UnsafeMutableAudioBufferListPointer,
        output: UnsafeMutableAudioBufferListPointer,
        recording: UnsafeMutableBufferPointer<Float>
    ) -> Int? {
        guard input.count == inputChannels.count, output.count == outputChannels.count else { return nil }

        let leftBuffer = input[left.buffer]
        let rightBuffer = input[right.buffer]
        let systemBuffer = input[tapBuffer]
        let leftStride = Int(inputChannels[left.buffer])
        let rightStride = Int(inputChannels[right.buffer])
        let frames = Int(leftBuffer.mDataByteSize) / (leftStride * MemoryLayout<Float>.size)
        guard frames <= recording.count / 2,
              let leftData = samples(leftBuffer, frames: frames, channels: leftStride),
              let rightData = samples(rightBuffer, frames: frames, channels: rightStride),
              let systemData = samples(systemBuffer, frames: frames, channels: 2)
        else { return nil }

        var cableData: UnsafeMutablePointer<Float>?
        if let cableBuffer {
            guard let data = samples(output[cableBuffer], frames: frames, channels: 2) else { return nil }
            cableData = data
        }

        for frame in 0..<frames {
            let index = frame * 2
            recording[index] = 0.5 * (level(leftData[frame * leftStride + left.index]) + level(systemData[index]))
            recording[index + 1] = 0.5 * (level(rightData[frame * rightStride + right.index]) + level(systemData[index + 1]))
        }
        if let cableData, let recordingData = recording.baseAddress {
            cableData.update(from: recordingData, count: frames * 2)
        }
        return frames
    }
}

private func samples(_ buffer: AudioBuffer, frames: Int, channels: Int) -> UnsafeMutablePointer<Float>? {
    guard buffer.mNumberChannels == channels,
          buffer.mDataByteSize == frames * channels * MemoryLayout<Float>.size
    else { return nil }
    return buffer.mData?.assumingMemoryBound(to: Float.self)
}

private func level(_ sample: Float) -> Float {
    sample.isFinite ? min(1, max(-1, sample)) : 0
}

public struct AudioCaptureError: LocalizedError {
    let message: String
    public let recordingFinalized: Bool

    init(_ message: String, recordingFinalized: Bool = true) {
        self.message = message
        self.recordingFinalized = recordingFinalized
    }

    public var errorDescription: String? { message }

    static func check(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else { throw AudioCaptureError("\(message) (Core Audio \(status)).") }
    }
}

// Bit 0 fences an in-flight write. Bit 1 prevents further writes after teardown begins.
final class CaptureIO: @unchecked Sendable {
    private let layout: CaptureLayout
    private let scratch: UnsafeMutableBufferPointer<Float>
    private let file: ExtAudioFileRef
    private let closed = Atomic<Bool>(false)
    private let gate = Atomic<UInt8>(0)
    private let submittedFrames = Atomic<UInt64>(0)
    private let failureStatus = Atomic<Int64>(0)

    init(layout: CaptureLayout, capacity: Int, sampleRate: Double, url: URL) throws {
        let frameBytes = UInt32(2 * MemoryLayout<Float>.size)
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: frameBytes,
            mFramesPerPacket: 1, mBytesPerFrame: frameBytes, mChannelsPerFrame: 2,
            mBitsPerChannel: 32, mReserved: 0
        )

        var destination: ExtAudioFileRef?
        try AudioCaptureError.check(
            ExtAudioFileCreateWithURL(url as CFURL, kAudioFileCAFType, &format, nil, 0, &destination),
            "Could not create the local audio recording"
        )
        guard let destination else { throw AudioCaptureError("Core Audio did not open the local recording.") }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // A zero-frame write initializes the Core Audio ring buffer outside realtime IO.
            try AudioCaptureError.check(
                ExtAudioFileWriteAsync(destination, 0, nil),
                "Could not initialize the local audio recording"
            )
        } catch {
            ExtAudioFileDispose(destination)
            throw error
        }

        self.layout = layout
        self.file = destination
        self.scratch = .allocate(capacity: 2 * capacity)
    }

    deinit {
        _ = close()
        scratch.deallocate()
    }

    var frames: UInt64 { submittedFrames.load(ordering: .relaxed) }
    var isWriting: Bool { gate.load(ordering: .acquiring) & 1 != 0 }

    var failure: AudioCaptureError? {
        let status = failureStatus.load(ordering: .acquiring)
        if status == 0 { return nil }
        if status == Int64.max {
            return AudioCaptureError("The audio buffers changed or were unavailable. Check the microphone, system audio permission, and VB-Cable.")
        }
        return AudioCaptureError("Could not write the local audio recording (Core Audio \(status)).")
    }

    func process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        guard gate.compareExchange(expected: 0, desired: 1, ordering: .acquiring).exchanged else { return }
        defer { _ = gate.wrappingSubtract(1, ordering: .releasing) }
        guard failureStatus.load(ordering: .relaxed) == 0 else { return }

        let input = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let output = UnsafeMutableAudioBufferListPointer(output)
        guard let frames = layout.mix(input: input, output: output, recording: scratch) else {
            failureStatus.store(Int64.max, ordering: .releasing)
            return
        }
        guard frames > 0 else { return }

        var buffer = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                mData: scratch.baseAddress
            )
        )
        let status = ExtAudioFileWriteAsync(file, UInt32(frames), &buffer)
        if status == noErr {
            _ = submittedFrames.wrappingAdd(UInt64(frames), ordering: .relaxed)
        } else {
            failureStatus.store(Int64(status), ordering: .releasing)
        }
    }

    func deactivate() {
        _ = gate.bitwiseOr(2, ordering: .acquiringAndReleasing)
    }

    func close() -> OSStatus {
        guard !closed.exchange(true, ordering: .acquiringAndReleasing) else { return noErr }
        return ExtAudioFileDispose(file)
    }
}
