import AVFoundation
import CoreAudio
import XCTest
@testable import OutputlyCore

final class AudioCaptureTests: XCTestCase {
    func testPinnedInputDoesNotFallBackToDefault() throws {
        let microphone = CaptureDevice(
            objectID: 1, uid: "physical", name: "Physical", transport: kAudioDeviceTransportTypeUSB,
            inputs: [2], outputs: [], modelUID: "mic"
        )

        XCTAssertEqual(
            CaptureDevice.microphone(in: [microphone], requestedUID: nil, defaultID: 1)?.uid,
            "physical"
        )
        XCTAssertNil(CaptureDevice.microphone(in: [microphone], requestedUID: "missing", defaultID: 1))
    }

    func testCableCanRouteAudioButCannotBeAPinnedMicrophone() {
        let cable = CaptureDevice(
            objectID: 2, uid: "installed-cable", name: "VB-Cable", transport: kAudioDeviceTransportTypeVirtual,
            inputs: [2], outputs: [2], modelUID: "com.vbaudio.vbcable.model:test"
        )
        let unsupported = CaptureDevice(
            objectID: 3, uid: "similarly-named", name: "VB-Cable", transport: kAudioDeviceTransportTypeVirtual,
            inputs: [2], outputs: [2], modelUID: "another-model"
        )

        XCTAssertEqual(CaptureDevice.cable(in: [unsupported, cable])?.uid, "installed-cable")
        XCTAssertNil(CaptureDevice.cable(in: [unsupported]))
        XCTAssertNil(CaptureDevice.microphone(in: [cable], requestedUID: "installed-cable", defaultID: 2))
    }

    func testMixOnlyRoutesSelectedMicrophoneChannelsAndTapToCable() throws {
        let layout = try CaptureLayout(
            microphoneInputs: [6], microphoneOutputs: [2], preferredMicrophoneChannels: [1, 2],
            live: true
        )

        withBuffers([[1, 0.5, 1, 1, 1, 1], [-1, -1], [0, 0.25]], channels: [6, 2, 2]) { input in
            withBuffers([[0, 0], [0, 0]], channels: [2, 2]) { output in
                var recording: [Float] = [0, 0]
                let frames = recording.withUnsafeMutableBufferPointer {
                    layout.mix(input: input, output: output, recording: $0)
                }

                XCTAssertEqual(frames, 1)
                XCTAssertEqual(recording, [0.5, 0.375])
                XCTAssertEqual(samples(output[0]), [0, 0])
                XCTAssertEqual(samples(output[1]), recording)
            }
        }
    }

    func testMixDuplicatesMonoAndKeepsStereoTapWithinHeadroom() throws {
        let layout = try CaptureLayout(
            microphoneInputs: [1], microphoneOutputs: [], preferredMicrophoneChannels: [1, 1],
            live: false
        )

        withBuffers([[1, -1], [1, 0, -1, -.infinity]], channels: [1, 2]) { input in
            withBuffers([], channels: []) { output in
                var recording: [Float] = [0, 0, 0, 0]
                let frames = recording.withUnsafeMutableBufferPointer {
                    layout.mix(input: input, output: output, recording: $0)
                }

                XCTAssertEqual(frames, 2)
                XCTAssertEqual(recording, [1, 0.5, -1, -0.5])
            }
        }
    }

    func testMixRejectsMismatchedFrameCountsBeforeWriting() throws {
        let layout = try CaptureLayout(
            microphoneInputs: [1], microphoneOutputs: [], preferredMicrophoneChannels: nil,
            live: true
        )

        withBuffers([[0.5, 0.25], [0, 0, 0, 0], [0, 0]], channels: [1, 2, 2]) { input in
            withBuffers([[0, 0, 0, 0]], channels: [2]) { output in
                var recording: [Float] = [0, 0, 0, 0]
                let frames = recording.withUnsafeMutableBufferPointer {
                    layout.mix(input: input, output: output, recording: $0)
                }

                XCTAssertNil(frames)
                XCTAssertEqual(recording, [0, 0, 0, 0])
                XCTAssertEqual(samples(output[0]), recording)
            }
        }
    }

    func testDeactivatedWriterFlushesOnlyPreviouslySubmittedAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "source.caf")
        let layout = try CaptureLayout(
            microphoneInputs: [1], microphoneOutputs: [], preferredMicrophoneChannels: nil, live: false
        )
        let io = try CaptureIO(layout: layout, capacity: 2, sampleRate: 44_100, url: url)

        withBuffers([[1, 0.5], [0, 0.5, 0, 0]], channels: [1, 2]) { input in
            withBuffers([], channels: []) { output in
                io.process(input: input.unsafePointer, output: output.unsafeMutablePointer)
                io.deactivate()
                io.process(input: input.unsafePointer, output: output.unsafeMutablePointer)
            }
        }
        XCTAssertEqual(io.close(), noErr)

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 2)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2))
        try file.read(into: pcm)
        let channels = try XCTUnwrap(pcm.floatChannelData)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channels[0], count: 2)), [0.5, 0.25])
        XCTAssertEqual(Array(UnsafeBufferPointer(start: channels[1], count: 2)), [0.75, 0.25])
    }

    private func withBuffers(
        _ samples: [[Float]],
        channels: [UInt32],
        _ body: (UnsafeMutableAudioBufferListPointer) -> Void
    ) {
        let list = AudioBufferList.allocate(maximumBuffers: max(1, channels.count))
        list.unsafeMutablePointer.pointee.mNumberBuffers = UInt32(channels.count)
        defer {
            for buffer in list { buffer.mData?.deallocate() }
            list.unsafeMutablePointer.deallocate()
        }

        for index in channels.indices {
            let values = samples[index]
            let data = UnsafeMutablePointer<Float>.allocate(capacity: values.count)
            values.withUnsafeBufferPointer { data.initialize(from: $0.baseAddress!, count: values.count) }
            list[index] = AudioBuffer(
                mNumberChannels: channels[index],
                mDataByteSize: UInt32(values.count * MemoryLayout<Float>.size),
                mData: data
            )
        }
        body(list)
    }

    private func samples(_ buffer: AudioBuffer) -> [Float] {
        Array(UnsafeBufferPointer(
            start: buffer.mData?.assumingMemoryBound(to: Float.self),
            count: Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        ))
    }
}
