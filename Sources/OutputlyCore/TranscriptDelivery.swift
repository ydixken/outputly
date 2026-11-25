import Darwin
import Foundation

public enum Destination: String, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case claudeCode = "Claude Code"

    public var id: String { rawValue }
}

public enum TranscriptDelivery {
    public static func send(_ text: String, to destination: Destination) async throws -> String {
        try await send(text, to: destination, environment: ProcessInfo.processInfo.environment)
    }

    static func send(_ text: String, to destination: Destination, environment: [String: String]) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError.emptyTranscript
        }

        let command: Executable
        let arguments: [String]
        switch destination {
        case .codex:
            command = .codex
            arguments = [
                "--ask-for-approval", "never", "exec", "--skip-git-repo-check", "--sandbox", "read-only",
                "--ephemeral", "--ignore-user-config", "--disable", "shell_tool", "--disable", "hooks",
                "--disable", "plugins", "--disable", "apps", "-c", "web_search=\"disabled\"", "--color", "never", "-",
            ]
        case .claudeCode:
            command = .claude
            arguments = [
                "--print", "--safe-mode", "--tools", "", "--disallowed-tools", "*", "--disable-slash-commands",
                "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence", "--no-chrome",
            ]
        }
        let executable = try command.resolve(in: environment)
        let response: String
        do {
            response = try await Subprocess.offMain {
                let workspace = try privateDirectory(in: FileManager.default.temporaryDirectory, named: "outputly-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: workspace) }
                return try Subprocess.run(
                    executable, arguments: arguments, input: Data(text.utf8), directory: workspace,
                    environment: command.childEnvironment(from: environment)
                )
            }
        } catch CLIError.processTimedOut {
            throw CLIError.sendTimedOut(destination)
        } catch {
            throw CLIError.sendFailed(destination)
        }
        let result = response.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw CLIError.emptyResponse(destination) }
        return result
    }
}

enum Executable: String {
    case ffmpeg, codex, claude

    func resolve(in environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        let override = "OUTPUTLY_\(rawValue.uppercased())"
        let candidates = environment[override].map { [$0] } ?? searchPaths(in: environment).map { "\($0)/\(rawValue)" }
        for path in candidates where path.hasPrefix("/") {
            var isDirectory: ObjCBool = false
            let files = FileManager.default
            if files.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue, files.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw CLIError.missingExecutable(rawValue, override)
    }

    func childEnvironment(from source: [String: String]) -> [String: String] {
        let common: Set<String> = ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "SSL_CERT_FILE", "SSL_CERT_DIR"]
        let authentication: Set<String>
        switch self {
        case .codex: authentication = ["CODEX_HOME", "CODEX_API_KEY", "OPENAI_API_KEY"]
        case .claude: authentication = ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]
        case .ffmpeg: authentication = []
        }
        let allowed = common.union(authentication)
        var environment = source.filter { allowed.contains($0.key) }
        environment["PATH"] = searchPaths(in: source).joined(separator: ":")
        return environment
    }

    private func searchPaths(in environment: [String: String]) -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = (environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0.hasPrefix("/") }
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] + paths
    }
}

enum Subprocess {
    static func run(
        _ executable: URL, arguments: [String], input: Data? = nil, directory: URL? = nil,
        environment: [String: String] = Executable.ffmpeg.childEnvironment(from: ProcessInfo.processInfo.environment),
        timeout: DispatchTimeInterval = .seconds(300)
    ) throws -> String {
        let storage = directory ?? FileManager.default.temporaryDirectory
        let output = try anonymousFile(in: storage)
        defer { try? output.close() }
        let inputFile = try input.map { _ in try anonymousFile(in: storage) }
        defer { try? inputFile?.close() }
        if let input, let inputFile {
            try inputFile.write(contentsOf: input)
            try inputFile.seek(toOffset: 0)
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.environment = environment
        process.standardError = FileHandle.nullDevice
        process.standardOutput = output
        process.standardInput = inputFile ?? FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning { process.terminate() }
            _ = finished.wait(timeout: .now() + .seconds(2))
            throw CLIError.processTimedOut
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw CLIError.processFailed }

        try output.seek(toOffset: 0)
        let responseLimit = 4 * 1024 * 1024
        let response = try output.read(upToCount: responseLimit + 1) ?? Data()
        guard response.count <= responseLimit else { throw CLIError.processFailed }
        return String(decoding: response, as: UTF8.self)
    }

    private static func anonymousFile(in directory: URL) throws -> FileHandle {
        var path = directory.appending(path: ".outputly-XXXXXX").path.utf8CString
        return try path.withUnsafeMutableBufferPointer { bytes in
            guard let template = bytes.baseAddress else { throw CLIError.processFailed }
            let descriptor = mkstemp(template)
            guard descriptor >= 0 else { throw CLIError.processFailed }
            // Unlink before writing so transcript content never has a filesystem path.
            guard unlink(template) == 0, fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else {
                _ = Darwin.close(descriptor)
                throw CLIError.processFailed
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }
    }

    static func offMain<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result(catching: operation))
            }
        }
    }
}

private enum CLIError: LocalizedError {
    case missingExecutable(String, String)
    case emptyTranscript
    case emptyResponse(Destination)
    case sendFailed(Destination)
    case sendTimedOut(Destination)
    case processTimedOut
    case processFailed

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let name, let override):
            "Could not find an executable \(name). Install it or set \(override) to its absolute path."
        case .emptyTranscript:
            "No speech was recognized to send."
        case .emptyResponse(let destination):
            "\(destination.rawValue) did not return a response."
        case .sendFailed(let destination):
            "Could not complete the request to \(destination.rawValue). Check that its CLI is current and signed in."
        case .sendTimedOut(let destination):
            "\(destination.rawValue) timed out. It may have received the transcript."
        case .processTimedOut:
            "The external command timed out."
        case .processFailed:
            "The external command failed."
        }
    }
}
