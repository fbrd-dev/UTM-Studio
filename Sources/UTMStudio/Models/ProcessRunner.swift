import Foundation

struct ProcessResult {
    let exitCode: Int32
    let output: String
}

/// Mutable accumulator shared between the readability and termination
/// handlers; all access is confined to ProcessRunner's private serial queue.
private final class OutputBox: @unchecked Sendable {
    var buffer = Data()
    var fullOutput = ""
}

/// Thin async wrapper around Process/Pipe. Always shells through `/usr/bin/env`
/// so a bare command name (e.g. "utmctl") is resolved via PATH the same way it
/// would be from a Terminal, while a full path still works unchanged.
enum ProcessRunner {
    @discardableResult
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        onOutput: @escaping (String) -> Void = { _ in }
    ) async -> ProcessResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<ProcessResult, Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments

            var env = ProcessInfo.processInfo.environment
            for (key, value) in environment { env[key] = value }
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            // Both the readability handler and the termination handler can
            // fire on different background queues; serialize their access
            // to the shared buffer/output state through this queue.
            let syncQueue = DispatchQueue(label: "ProcessRunner.output")
            let newline = Data([0x0A])
            let box = OutputBox()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                syncQueue.async {
                    box.buffer.append(data)
                    while let range = box.buffer.range(of: newline) {
                        let lineData = box.buffer.subdata(in: box.buffer.startIndex..<range.lowerBound)
                        box.buffer.removeSubrange(box.buffer.startIndex..<range.upperBound)
                        let line = String(data: lineData, encoding: .utf8) ?? ""
                        box.fullOutput += line + "\n"
                        DispatchQueue.main.async { onOutput(line) }
                    }
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                syncQueue.async {
                    if !box.buffer.isEmpty {
                        let line = String(data: box.buffer, encoding: .utf8) ?? ""
                        box.fullOutput += line
                        DispatchQueue.main.async { onOutput(line) }
                    }
                    let finalOutput = box.fullOutput
                    continuation.resume(returning: ProcessResult(exitCode: proc.terminationStatus, output: finalOutput))
                }
            }

            do {
                try process.run()
            } catch {
                let message = "Failed to launch '\(executable)': \(error.localizedDescription)"
                DispatchQueue.main.async { onOutput(message) }
                continuation.resume(returning: ProcessResult(exitCode: -1, output: message))
            }
        }
    }
}
