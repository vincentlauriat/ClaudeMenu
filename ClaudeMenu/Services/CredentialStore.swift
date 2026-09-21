import Foundation

enum CredentialError: LocalizedError {
    case notFound
    case expired
    case malformed

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Aucun jeton Claude Code trouvé. Connecte-toi une fois avec « claude »."
        case .expired:
            return "Le jeton Claude Code a expiré. Lance « claude » une fois pour le renouveler."
        case .malformed:
            return "Les identifiants Claude Code enregistrés sont illisibles."
        }
    }
}

/// Reads the OAuth access token that Claude Code stores for the logged-in user.
///
/// - macOS: keychain item `Claude Code-credentials` (read through `/usr/bin/security`,
///   the same tool Claude Code uses to write it, so no extra ACL prompt).
/// - Fallback: `~/.claude/.credentials.json`.
///
/// The token is never persisted by this app; it only lives in memory for the request.
enum CredentialStore {
    private static let keychainService = "Claude Code-credentials"

    static func accessToken() throws -> String {
        if let json = readKeychain() ?? readFile() {
            return try parse(json)
        }
        throw CredentialError.notFound
    }

    private static func readKeychain() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        // `security -w` prints the secret followed by a newline.
        guard let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return text.data(using: .utf8)
    }

    private static func readFile() -> Data? {
        let url = ClaudePaths.configDir.appendingPathComponent(".credentials.json")
        return try? Data(contentsOf: url)
    }

    private static func parse(_ data: Data) throws -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialError.malformed
        }
        let creds = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let token = creds["accessToken"] as? String, !token.isEmpty else {
            throw CredentialError.malformed
        }
        if let expiresAt = creds["expiresAt"] as? Double {
            // Stored in milliseconds since the epoch.
            if expiresAt / 1000 <= Date().timeIntervalSince1970 {
                throw CredentialError.expired
            }
        }
        return token
    }
}

/// Where Claude Code keeps its state (honours `CLAUDE_CONFIG_DIR`).
enum ClaudePaths {
    static var configDir: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    static var projectsDir: URL { configDir.appendingPathComponent("projects") }
}
