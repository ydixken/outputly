import AVFoundation
import Darwin
import Foundation

public struct RecordingFiles: Sendable {
    public let pcmURL: URL
    public let mp3URL: URL

    public static func create() throws -> Self {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Music/Outputly", directoryHint: .isDirectory)
        return try create(in: directory)
    }

    public func removeEmptyWorkspace() {
        _ = rmdir(pcmURL.deletingLastPathComponent().path)
    }

    static func create(in directory: URL) throws -> Self {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try checkPrivateDirectory(directory)

        let timestamp = Date.now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false).timeSeparator(.omitted))
        let name = "\(timestamp)-\(UUID().uuidString.lowercased())"
        let workspace = try privateDirectory(in: directory, named: ".\(name)")
        return Self(
            pcmURL: workspace.appending(path: "recording.caf"),
            mp3URL: directory.appending(path: "\(name).mp3")
        )
    }
}

public enum MP3Export {
    public static func checkAvailability() throws {
        let ffmpeg = try Executable.ffmpeg.resolve()
        guard let output = try? Subprocess.run(ffmpeg, arguments: ["-hide_banner", "-encoders"], timeout: .seconds(10)),
              output.split(separator: "\n").contains(where: { line in
                  let fields = line.split(whereSeparator: \.isWhitespace)
                  return fields.count >= 2 && fields[0].first == "A" && fields[1] == "libmp3lame"
              }) else {
            throw DeliveryError.encoderUnavailable
        }
    }

    public static func encode(_ files: RecordingFiles) async throws {
        try await encode(files, using: try? Executable.ffmpeg.resolve())
    }

    static func encode(_ files: RecordingFiles, using ffmpeg: URL?) async throws {
        let failure = DeliveryError.exportFailed(files.pcmURL)
        guard let ffmpeg else { throw failure }
        let workspace = files.pcmURL.deletingLastPathComponent()
        let partial = workspace.appending(path: "\(UUID().uuidString).mp3")
        let fileManager = FileManager.default
        defer { try? fileManager.removeItem(at: partial) }
        do {
            try await Subprocess.offMain {
                _ = try Subprocess.run(ffmpeg, arguments: [
                    "-hide_banner", "-nostdin", "-loglevel", "error", "-n", "-i", files.pcmURL.path,
                    "-map", "0:a:0", "-map_metadata", "-1", "-ac", "2", "-c:a", "libmp3lame", "-q:a", "2", partial.path,
                ], timeout: .seconds(1800))
                let audio = try AVAudioFile(forReading: partial)
                guard audio.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEGLayer3,
                      audio.processingFormat.channelCount == 2,
                      audio.length > 0 else { throw failure }
                audio.close()
                guard chmod(partial.path, 0o600) == 0,
                      renamex_np(partial.path, files.mp3URL.path, UInt32(RENAME_EXCL)) == 0 else { throw failure }
            }
        } catch {
            throw failure
        }

        try? fileManager.removeItem(at: files.pcmURL)
        files.removeEmptyWorkspace()
    }
}

func privateDirectory(in directory: URL, named name: String) throws -> URL {
    let workspace = directory.appending(path: name, directoryHint: .isDirectory)
    guard mkdir(workspace.path, 0o700) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    do {
        try checkPrivateDirectory(workspace, clearInheritedACL: true)
        return workspace
    } catch {
        _ = rmdir(workspace.path)
        throw error
    }
}

private func checkPrivateDirectory(_ directory: URL, clearInheritedACL: Bool = false) throws {
    let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw DeliveryError.unsafeRecordingDirectory }
    defer { _ = Darwin.close(descriptor) }
    var status = stat()
    guard fstat(descriptor, &status) == 0, status.st_uid == getuid(), status.st_mode & 0o022 == 0 else {
        throw DeliveryError.unsafeRecordingDirectory
    }
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
        guard errno == ENOENT || errno == ENOATTR else { throw DeliveryError.unsafeRecordingDirectory }
        return
    }
    defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }
    guard clearInheritedACL, let emptyACL = acl_init(0) else { throw DeliveryError.unsafeRecordingDirectory }
    defer { _ = acl_free(UnsafeMutableRawPointer(emptyACL)) }
    guard acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED) == 0 else { throw DeliveryError.unsafeRecordingDirectory }
}

private enum DeliveryError: LocalizedError {
    case unsafeRecordingDirectory
    case encoderUnavailable
    case exportFailed(URL)

    var errorDescription: String? {
        switch self {
        case .unsafeRecordingDirectory:
            "Outputly needs a recording folder in Music that you own, with no shared write permissions or access control list."
        case .encoderUnavailable:
            "FFmpeg does not list the libmp3lame MP3 encoder. Choose a build that includes libmp3lame."
        case .exportFailed(let pcm):
            if FileManager.default.fileExists(atPath: pcm.path) {
                "Could not export a stereo MP3. The source audio was kept at \(pcm.path). Check FFmpeg and available disk space."
            } else {
                "Could not export a stereo MP3. Check FFmpeg and available disk space."
            }
        }
    }
}
