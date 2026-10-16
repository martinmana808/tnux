import Foundation

/// Reads the moment of the user's last real message in a Claude Code session
/// transcript (`~/.claude/projects/<project-slug>/<session-id>.jsonl`).
///
/// The transcript is the only source that knows about actions older than
/// cmux's own stamps (the stamp store was born on 2026-10-02; the sessions
/// go back months). Its file modification time is useless for this, since a
/// `claude --resume` rewrites the file, so the tail is parsed instead: each
/// line is one JSON object with a `type` and a `timestamp`, and a human
/// message is a `user` entry whose content is text (tool results are also
/// `user` entries, but with a `tool_result` content list).
enum ClaudeTranscriptLastAction {
    static var defaultProjectsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("projects", isDirectory: true)
    }

    /// The transcript file for a session id, searched across every project
    /// slug under the projects root. Returns nil when no file exists.
    static func transcriptURL(sessionId: String, projectsRoot: URL = defaultProjectsRoot) -> URL? {
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, UUID(uuidString: trimmed) != nil else { return nil }
        let fileManager = FileManager.default
        guard let slugs = try? fileManager.contentsOfDirectory(atPath: projectsRoot.path) else { return nil }
        let fileName = "\(trimmed).jsonl"
        for slug in slugs {
            let candidate = projectsRoot.appendingPathComponent(slug, isDirectory: true).appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// The timestamp of the last human message in the transcript, reading
    /// the file tail only (growing the window until a human message is
    /// found or `maxBytes` is reached).
    static func lastHumanMessageDate(
        in url: URL,
        tailBytes: Int = 256 * 1024,
        maxBytes: Int = 8 * 1024 * 1024
    ) -> Date? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd() else { return nil }
        var window = UInt64(max(1024, tailBytes))
        while true {
            let offset = fileSize > window ? fileSize - window : 0
            guard (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.readToEnd(),
                  let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
            else { return nil }
            var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            if offset > 0, !lines.isEmpty {
                lines.removeFirst() // partial line at the window edge
            }
            if let date = lastHumanMessageDate(lines: lines) {
                return date
            }
            if offset == 0 || window >= UInt64(maxBytes) {
                return nil
            }
            window = min(window * 4, UInt64(maxBytes))
        }
    }

    /// Pure: scans the lines newest to oldest and returns the first human
    /// message timestamp.
    static func lastHumanMessageDate(lines: [Substring]) -> Date? {
        for line in lines.reversed() {
            guard line.contains("\"user\""), let object = parseObject(line) else { continue }
            guard isHumanMessage(object), let raw = object["timestamp"] as? String, let date = parseTimestamp(raw) else {
                continue
            }
            return date
        }
        return nil
    }

    static func isHumanMessage(_ object: [String: Any]) -> Bool {
        guard (object["type"] as? String) == "user" else { return false }
        if (object["isMeta"] as? Bool) == true { return false }
        guard let message = object["message"] as? [String: Any] else { return false }
        if let role = message["role"] as? String, role != "user" { return false }
        if let text = message["content"] as? String {
            return isHumanText(text)
        }
        if let parts = message["content"] as? [[String: Any]], !parts.isEmpty {
            // Tool results arrive as `user` entries too; only pure text counts.
            guard parts.allSatisfy({ ($0["type"] as? String) == "text" }) else { return false }
            let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return isHumanText(text)
        }
        return false
    }

    /// Slash commands and their echoed output are written as user entries
    /// wrapped in command tags; those are not messages the user wrote.
    private static func isHumanText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        for tag in ["<command-name>", "<command-message>", "<local-command-stdout>", "<local-command-caveat>"] {
            if trimmed.hasPrefix(tag) { return false }
        }
        return true
    }

    private static func parseObject(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parseTimestamp(_ raw: String) -> Date? {
        fractionalFormatter.date(from: raw) ?? plainFormatter.date(from: raw)
    }
}
