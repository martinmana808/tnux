import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The age gauge's source of truth: the last message the user wrote in a
/// Claude transcript, not the file's modification time and not tool results.
@Suite("Claude transcript last action")
struct ClaudeTranscriptLastActionTests {
    private func line(_ type: String, _ ts: String, content: String, extra: String = "") -> Substring {
        Substring("{\"type\":\"\(type)\",\"timestamp\":\"\(ts)\",\"message\":{\"role\":\"\(type)\",\"content\":\(content)}\(extra)}")
    }

    private func date(_ iso: String) -> Date { ClaudeTranscriptLastAction.parseTimestamp(iso)! }

    @Test("the newest human text message wins")
    func newestHumanMessage() {
        let lines: [Substring] = [
            line("user", "2026-09-03T21:50:00.000Z", content: "\"fix the login\""),
            line("assistant", "2026-09-03T21:50:30.000Z", content: "[{\"type\":\"text\",\"text\":\"done\"}]"),
            line("user", "2026-09-26T14:43:00.000Z", content: "\"and the signup\""),
            line("assistant", "2026-09-26T14:43:33.000Z", content: "[{\"type\":\"text\",\"text\":\"ok\"}]"),
        ]
        #expect(ClaudeTranscriptLastAction.lastHumanMessageDate(lines: lines) == date("2026-09-26T14:43:00.000Z"))
    }

    @Test("tool results, meta entries and slash commands are not actions")
    func ignoresNonHumanUserEntries() {
        let lines: [Substring] = [
            line("user", "2026-09-26T14:43:00.000Z", content: "\"real prompt\""),
            line("user", "2026-10-09T18:27:00.000Z", content: "[{\"type\":\"tool_result\",\"tool_use_id\":\"x\",\"content\":\"ok\"}]"),
            line("user", "2026-10-10T18:27:00.000Z", content: "\"<command-name>/clear</command-name>\""),
            line("user", "2026-10-11T18:27:00.000Z", content: "\"caveat\"", extra: ",\"isMeta\":true"),
            Substring("not json at all"),
        ]
        #expect(ClaudeTranscriptLastAction.lastHumanMessageDate(lines: lines) == date("2026-09-26T14:43:00.000Z"))
    }

    @Test("text-part lists count as human messages")
    func textPartsCount() {
        let lines: [Substring] = [
            line("user", "2026-09-26T14:43:00Z", content: "[{\"type\":\"text\",\"text\":\"hello\"}]"),
        ]
        #expect(ClaudeTranscriptLastAction.lastHumanMessageDate(lines: lines) == date("2026-09-26T14:43:00Z"))
        #expect(ClaudeTranscriptLastAction.lastHumanMessageDate(lines: []) == nil)
    }

    @Test("reads the tail of a large file and grows the window when needed")
    func readsTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        var text = String(line("user", "2026-09-26T14:43:00.000Z", content: "\"prompt\"")) + "\n"
        let filler = String(repeating: "x", count: 4000)
        for index in 0..<200 {
            text += line("assistant", "2026-09-26T15:00:\(String(format: "%02d", index % 60)).000Z", content: "[{\"type\":\"text\",\"text\":\"\(filler)\"}]") + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        // 200 × ~4 KB of assistant output sits after the prompt; a 16 KB tail must grow to find it.
        #expect(ClaudeTranscriptLastAction.lastHumanMessageDate(in: url, tailBytes: 16 * 1024) == date("2026-09-26T14:43:00.000Z"))
        #expect(ClaudeTranscriptLastAction.lastHumanMessageDate(in: url, tailBytes: 16 * 1024, maxBytes: 32 * 1024) == nil, "stops at maxBytes")
    }

    @Test("finds a session file under any project slug")
    func locatesTranscript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-projects-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionId = UUID().uuidString.lowercased()
        let slug = root.appendingPathComponent("-Users-x-proj")
        try FileManager.default.createDirectory(at: slug, withIntermediateDirectories: true)
        try "{}\n".write(to: slug.appendingPathComponent("\(sessionId).jsonl"), atomically: true, encoding: .utf8)
        #expect(ClaudeTranscriptLastAction.transcriptURL(sessionId: sessionId, projectsRoot: root)?.lastPathComponent == "\(sessionId).jsonl")
        #expect(ClaudeTranscriptLastAction.transcriptURL(sessionId: "nope", projectsRoot: root) == nil)
    }

    @MainActor
    @Test("workspace merge: later wins, replacing overrides, missing stays unknown")
    func workspaceMerge() throws {
        let workspace = Workspace()
        let panelId = try #require(workspace.orderedPanelIds.first)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try (String(line("user", "2026-09-26T14:43:00.000Z", content: "\"prompt\"")) + "\n").write(to: url, atomically: true, encoding: .utf8)

        #expect(workspace.refreshLastActionFromTranscript(panelId: panelId) == false, "no transcript known: nothing to merge")
        workspace.noteTranscriptPath(url.path, panelId: panelId)
        #expect(workspace.refreshLastActionFromTranscript(panelId: panelId) == true)
        #expect(workspace.panelLastFocusedAt[panelId] == date("2026-09-26T14:43:00.000Z"))

        // A bogus newer stamp (written when focus still counted) survives a plain merge...
        let bogus = date("2026-10-02T15:15:00Z")
        workspace.panelLastFocusedAt[panelId] = bogus
        #expect(workspace.refreshLastActionFromTranscript(panelId: panelId) == false)
        #expect(workspace.panelLastFocusedAt[panelId] == bogus)
        // ...and is retired by the one-time replacing pass.
        #expect(workspace.refreshLastActionFromTranscript(panelId: panelId, replacing: true) == true)
        #expect(workspace.panelLastFocusedAt[panelId] == date("2026-09-26T14:43:00.000Z"))

        // A real later action (Enter today) beats the transcript.
        let today = Date()
        workspace.notePaneAction(panelId: panelId, at: today)
        #expect(workspace.refreshLastActionFromTranscript(panelId: panelId) == false)
        #expect(workspace.panelLastFocusedAt[panelId] == today)
    }
}
