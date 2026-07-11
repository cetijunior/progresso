import Foundation

/// Sync state of the active board, shown in the sidebar.
enum GitSyncState: Equatable {
    case notGit          // plain folder board — no sync UI
    case idle            // in sync
    case syncing
    case error(String)
}

/// Thin wrapper around /usr/bin/git. All blocking — call from a background task.
enum Git {
    static func run(_ args: [String], in dir: String) -> (ok: Bool, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            return (false, "git failed to launch: \(error.localizedDescription)")
        }
        p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                         encoding: .utf8) ?? ""
        return (p.terminationStatus == 0, out)
    }

    static func isRepo(_ dir: String) -> Bool {
        FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(".git"))
    }

    /// Make sure commits are attributable even on a machine with no git setup.
    static func ensureIdentity(in dir: String) {
        let email = run(["config", "user.email"], in: dir)
        if !email.ok || email.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            _ = run(["config", "user.name", NSFullUserName()], in: dir)
            _ = run(["config", "user.email", "\(NSUserName())@progresso.local"], in: dir)
        }
    }
}
