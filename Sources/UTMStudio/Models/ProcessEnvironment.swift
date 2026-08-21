import Foundation

/// GUI apps launched via Finder/Dock/Xcode do NOT inherit the PATH an
/// interactive shell sets up (.zprofile/.zshrc, Homebrew's `eval "$(brew
/// shellenv)"`) — they get a bare minimal PATH (roughly /usr/bin:/bin:
/// /usr/sbin:/sbin). So a bare command name we (or utm-client.sh) spawn can
/// fail here even though it works fine from Terminal. Prepend the common
/// Homebrew locations plus wherever the user's configured tool paths
/// actually live, so both the script and our own subprocess calls find
/// things reliably.
enum ProcessEnvironment {
    static func augmentedPATH(extraToolPaths: [String] = []) -> String {
        let current = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var candidateDirs = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"]
        for toolPath in extraToolPaths {
            let dir = (toolPath as NSString).deletingLastPathComponent
            if !dir.isEmpty { candidateDirs.append(dir) }
        }

        let existing = Set(current.split(separator: ":").map(String.init))
        let newDirs = candidateDirs.filter { !$0.isEmpty && !existing.contains($0) }
        return (newDirs + [current]).joined(separator: ":")
    }
}
