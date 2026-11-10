import Foundation

/// Runs a system tool with an argument array (never through a shell) and collects its output.
public enum ProcessRunner {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: Data
        public var stderr: Data

        public var text: String { String(decoding: stdout, as: UTF8.self) }
        public var errorText: String { String(decoding: stderr, as: UTF8.self) }
    }

    public static func run(
        _ executable: String, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 15
    ) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let environment { process.environment = environment }
                let out = Pipe(), err = Pipe()
                process.standardInput = FileHandle.nullDevice
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                deadline.cancel()
                continuation.resume(returning: Output(status: process.terminationStatus, stdout: outData, stderr: errData))
            }
        }
    }
}

/// A short, private folder for Unix sockets. Socket paths are limited to 104 bytes and `ssh` appends
/// 17 characters to its control path, so the per-user temporary folder is too deep.
public enum RuntimeDirectory {
    public static func url(base: String = "/tmp") -> URL? {
        let path = "\(base)/navette-\(getuid())"
        mkdir(path, 0o700)
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
