import Foundation

struct ShellResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var ok: Bool { exitCode == 0 }
}

enum Shell {
    /// Run an executable to completion, capturing output. Off the main thread by
    /// virtue of being async; callers `await` it.
    static func run(_ executable: URL, _ args: [String]) async throws -> ShellResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: ShellResult(
                    exitCode: process.terminationStatus,
                    stdout: String(data: outData, encoding: .utf8) ?? "",
                    stderr: String(data: errData, encoding: .utf8) ?? ""
                ))
            }
        }
    }

    /// Stream stdout lines as they arrive (used for yt-dlp progress). Returns the
    /// exit code once the process ends. The line handler runs on a background queue.
    static func stream(
        _ executable: URL,
        _ args: [String],
        onLine: @escaping (String) -> Void
    ) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = args
                let outPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = outPipe

                let handle = outPipe.fileHandleForReading
                var buffer = Data()
                handle.readabilityHandler = { fh in
                    let chunk = fh.availableData
                    guard !chunk.isEmpty else { return }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                        buffer.removeSubrange(buffer.startIndex...nl)
                        if let line = String(data: lineData, encoding: .utf8) {
                            onLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    }
                }
                do {
                    try process.run()
                } catch {
                    handle.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                process.waitUntilExit()
                handle.readabilityHandler = nil
                if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) {
                    onLine(line.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                continuation.resume(returning: process.terminationStatus)
            }
        }
    }
}
