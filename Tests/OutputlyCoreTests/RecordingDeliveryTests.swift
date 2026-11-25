import AVFoundation
import Foundation
import XCTest
@testable import OutputlyCore

final class RecordingDeliveryTests: XCTestCase {
    func testRecordingPathsAreUniqueAndPrivate() throws {
        try withDirectory { directory in
            let first = try RecordingFiles.create(in: directory)
            let second = try RecordingFiles.create(in: directory)
            XCTAssertEqual(first.mp3URL.deletingLastPathComponent(), directory)
            XCTAssertNotEqual(first.mp3URL, second.mp3URL)
            XCTAssertNotEqual(first.pcmURL, second.pcmURL)
            XCTAssertEqual(first.pcmURL.pathExtension, "caf")
            let workingDirectory = first.pcmURL.deletingLastPathComponent()
            let attributes = try FileManager.default.attributesOfItem(atPath: workingDirectory.path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o700)
            XCTAssertFalse(FileManager.default.fileExists(atPath: first.mp3URL.path))
        }
    }

    func testRecordingDirectoryWithAnACLIsRejected() throws {
        try withDirectory { directory in
            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["+a", "everyone allow list,search,add_file,delete_child", directory.path]
            try chmod.run()
            chmod.waitUntilExit()
            XCTAssertEqual(chmod.terminationStatus, 0)
            XCTAssertThrowsError(try RecordingFiles.create(in: directory))
        }
    }

    func testCleanupRemovesOnlyAnEmptyWorkspace() throws {
        try withDirectory { directory in
            let files = try RecordingFiles.create(in: directory)
            try Data("recoverable audio".utf8).write(to: files.pcmURL)
            files.removeEmptyWorkspace()
            XCTAssertTrue(FileManager.default.fileExists(atPath: files.pcmURL.path))
            try FileManager.default.removeItem(at: files.pcmURL)
            files.removeEmptyWorkspace()
            XCTAssertFalse(FileManager.default.fileExists(atPath: files.pcmURL.deletingLastPathComponent().path))
        }
    }

    func testFailedExportKeepsPCMAndDiscardsPartialMP3() async throws {
        try await withDirectory { directory in
            let files = try RecordingFiles.create(in: directory)
            let original = Data("test source audio".utf8)
            try original.write(to: files.pcmURL)
            let encoder = try fakeExecutable(in: directory, script: """
                for argument do output="$argument"; done
                printf 'partial' > "$output"
                exit 1
                """)

            do {
                try await MP3Export.encode(files, using: encoder)
                XCTFail("Encoding failure must be surfaced")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(files.pcmURL.path))
            }
            XCTAssertEqual(try Data(contentsOf: files.pcmURL), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: files.mp3URL.path))
            let workingDirectory = files.pcmURL.deletingLastPathComponent()
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workingDirectory.path), [files.pcmURL.lastPathComponent])
        }
    }

    func testExportFailureReportsRecoveryOnlyWhenPCMExists() async throws {
        try await withDirectory { directory in
            let files = try RecordingFiles.create(in: directory)
            let encoder = try fakeExecutable(in: directory, script: "exit 1")
            do {
                try await MP3Export.encode(files, using: encoder)
                XCTFail("Encoding failure must be surfaced")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains(files.pcmURL.path))
            }
        }
    }

    func testExportPublishesStereoMP3ThenRemovesPCM() async throws {
        try await withDirectory { directory in
            let ffmpeg: URL
            do {
                try MP3Export.checkAvailability()
                ffmpeg = try Executable.ffmpeg.resolve()
            } catch {
                throw XCTSkip("FFmpeg with libmp3lame is required for this integration test")
            }

            let files = try RecordingFiles.create(in: directory)
            try writeMonoAudio(to: files.pcmURL)
            try await MP3Export.encode(files, using: ffmpeg)

            let mp3 = try AVAudioFile(forReading: files.mp3URL)
            XCTAssertEqual(mp3.processingFormat.channelCount, 2)
            XCTAssertGreaterThan(mp3.length, 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: files.pcmURL.path))
            let attributes = try FileManager.default.attributesOfItem(atPath: files.mp3URL.path)
            XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        }
    }

    func testDestinationsReceiveTranscriptOnlyOnStdin() async throws {
        try await withDirectory { directory in
            let executable = try fakeExecutable(in: directory, script: """
                [ ! -e .git ] || exit 21
                printf '%s\\n' "$@"
                printf '\\n--- stdin ---\\n'
                /bin/cat
                """)
            let transcript = "First \"line\"\n$(echo 'hello') & \u{1F44B}\n" + String(repeating: "audio words ", count: 12_000)
            for destination in Destination.allCases {
                let result = try await TranscriptDelivery.send(
                    transcript, to: destination,
                    environment: ["OUTPUTLY_CODEX": executable.path, "OUTPUTLY_CLAUDE": executable.path]
                )
                let segments = result.components(separatedBy: "\n--- stdin ---\n")
                XCTAssertEqual(segments.count, 2)
                XCTAssertFalse(segments[0].contains("First"))
                if destination == .codex {
                    XCTAssertTrue(segments[0].contains("exec\n--skip-git-repo-check\n--sandbox\nread-only\n--ephemeral\n"))
                } else {
                    XCTAssertTrue(segments[0].contains("--print\n--safe-mode\n--tools\n\n"))
                    XCTAssertTrue(segments[0].contains("--no-session-persistence\n"))
                }
                XCTAssertTrue(segments.last == transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    func testBlankTranscriptIsRejectedBeforeExecutableLookup() async throws {
        do {
            _ = try await TranscriptDelivery.send(" \n\t", to: .codex, environment: ["OUTPUTLY_CODEX": "/missing"])
            XCTFail("Whitespace must not be sent")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("No speech"))
        }
    }

    func testEarlyCLIExitNeverReturnsTranscriptInTheError() async throws {
        try await withDirectory { directory in
            let executable = try fakeExecutable(in: directory, script: """
                IFS= read -r transcript
                printf '%s\\n' "$transcript"
                printf '%s\\n' "$transcript" >&2
                exit 3
                """)
            let transcript = "private test phrase\n" + String(repeating: "a", count: 256_000)
            do {
                _ = try await TranscriptDelivery.send(transcript, to: .claudeCode, environment: ["OUTPUTLY_CLAUDE": executable.path])
                XCTFail("A failed process must not return success")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Claude Code"))
                XCTAssertFalse(error.localizedDescription.contains("private test phrase"))
            }
        }
    }

    func testResponseDoesNotWaitForAnInheritedOutputHandle() async throws {
        try await withDirectory { directory in
            let executable = try fakeExecutable(in: directory, script: """
                /bin/cat > /dev/null
                /bin/sleep 4 &
                printf 'response'
                """)
            let start = ContinuousClock.now
            let response = try await TranscriptDelivery.send(
                "test transcript", to: .codex, environment: ["OUTPUTLY_CODEX": executable.path]
            )
            XCTAssertEqual(response, "response")
            XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        }
    }

    func testSilentCommandTimesOut() throws {
        try withDirectory { directory in
            let executable = try fakeExecutable(in: directory, script: "exec /bin/sleep 4")
            let start = ContinuousClock.now
            XCTAssertThrowsError(try Subprocess.run(executable, arguments: [], timeout: .milliseconds(150))) { error in
                XCTAssertTrue(error.localizedDescription.contains("timed out"))
            }
            XCTAssertLessThan(start.duration(to: .now), .seconds(3))
        }
    }

    func testUnreadableFileIsRejectedBeforeSpeechModelSetup() async throws {
        try await withDirectory { directory in
            let file = directory.appendingPathComponent("missing.mp3")
            do {
                _ = try await LocalTranscript.transcribe(file)
                XCTFail("A missing MP3 must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("read the recording"))
            }
        }
    }
}

private func testDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

private func withDirectory(_ operation: (URL) throws -> Void) throws {
    let directory = try testDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try operation(directory)
}

private func withDirectory(_ operation: (URL) async throws -> Void) async throws {
    let directory = try testDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await operation(directory)
}

private func fakeExecutable(in directory: URL, script: String) throws -> URL {
    let executable = directory.appendingPathComponent("fake-cli")
    try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    return executable
}

private func writeMonoAudio(to url: URL) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    buffer.frameLength = buffer.frameCapacity
    let channel = try XCTUnwrap(buffer.floatChannelData)[0]
    channel.initialize(repeating: 0, count: Int(buffer.frameLength))
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
    file.close()
}
