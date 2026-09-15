import Foundation
import Testing
@testable import AgentPetCore

/// Exercises the waiting room for events that arrived while the runtime was
/// not running — which is the moment after a quit, a crash, or the SIGTERM a
/// Homebrew upgrade sends to the old app.
@Suite("Event spool")
struct EventSpoolTests {

    private let origin = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agentpet-spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func envelope(
        _ event: String,
        session: String = "sess-1",
        at offset: TimeInterval = 0,
        payload: [String: Any]? = nil
    ) -> BridgeEnvelope {
        let body: [String: Any] = payload ?? [
            "session_id": session,
            "cwd": "/Users/someone/project",
            "hook_event_name": event,
        ]
        return BridgeEnvelope(
            agentID: "claude-code",
            eventName: event,
            receivedAt: origin.addingTimeInterval(offset),
            proc: BridgeProcessInfo(pid: 100, ppid: 50, tty: "/dev/ttys001"),
            rawPayload: (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        )
    }

    @Test("what waits in the spool comes back whole")
    func roundTrip() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(EventSpool.write(envelope("PreToolUse", at: 5), to: directory))
        #expect(EventSpool.pendingCount(in: directory) == 1)

        var replayed: [BridgeEnvelope] = []
        let count = EventSpool.drain(from: directory) { replayed.append($0) }

        #expect(count == 1)
        let restored = try #require(replayed.first)
        #expect(restored.agentID == "claude-code")
        #expect(restored.eventName == "PreToolUse")
        #expect(restored.receivedAt == origin.addingTimeInterval(5))
        #expect(restored.proc?.ppid == 50, "the session-id fallback needs the parent pid")

        // And it still normalizes into the event it was.
        let event = try #require(
            EventNormalizer(profiles: AgentProfiles.all).normalize(restored).first
        )
        #expect(event.kind == .working)
        #expect(event.sessionID == "sess-1")

        #expect(EventSpool.pendingCount(in: directory) == 0, "replayed files must be removed")
    }

    @Test("nothing a user typed is written to disk")
    func payloadIsReduced() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // A payload shaped like the ones Claude Code really sends: the fields
        // the state machine needs, and the ones that are the user's own work.
        EventSpool.write(envelope("PreToolUse", payload: [
            "session_id": "sess-1",
            "cwd": "/Users/someone/project",
            "tool_name": "Bash",
            "tool_input": ["command": "cat ~/.ssh/id_rsa"],
            "tool_response": "PRIVATE KEY-----",
            "last_assistant_message": "I read the file.",
        ]), to: directory)

        var replayed: [BridgeEnvelope] = []
        EventSpool.drain(from: directory) { replayed.append($0) }
        let text = String(decoding: try #require(replayed.first).rawPayload, as: UTF8.self)

        #expect(text.contains("sess-1"), "the session id is needed to tell sessions apart")
        #expect(text.contains("Bash"), "the tool name is a label, not content")
        #expect(!text.contains("id_rsa"), "tool arguments are not ours to keep")
        #expect(!text.contains("PRIVATE KEY"), "tool output is not ours to keep")
        #expect(!text.contains("I read the file"), "model output is not ours to keep")
    }

    @Test("a payload written in an extension's own spelling keeps its identity")
    func extensionSpellingKeepsItsIdentity() throws {
        // The regression this exists for: the allowlist knew only Claude Code's
        // `session_id` / `tool_name`, so a payload that spelled its session id
        // only in camelCase was spooled without one, and replaying it after a
        // restart drew that session under a process-derived name, beside the
        // real one. The envelope below is shaped like such a payload; the
        // redaction path itself does not care which agent it came from.
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        EventSpool.write(
            BridgeEnvelope(
                agentID: "generic-cli",
                eventName: "tool_execution_start",
                receivedAt: origin,
                proc: BridgeProcessInfo(pid: 100, ppid: 50, tty: nil),
                rawPayload: (try? JSONSerialization.data(withJSONObject: [
                    "sessionId": "01a0a2d8-1028-7000-a617-ffb53b950be5",
                    "cwd": "/tmp/project",
                    "toolName": "bash",
                    "args": ["command": "cat ~/.ssh/id_rsa"],
                    "text": "the user's own words",
                ])) ?? Data()
            ),
            to: directory
        )

        var replayed: [BridgeEnvelope] = []
        EventSpool.drain(from: directory) { replayed.append($0) }
        let text = String(decoding: try #require(replayed.first).rawPayload, as: UTF8.self)

        #expect(text.contains("01a0a2d8-1028-7000-a617-ffb53b950be5"),
                "a replayed event must keep its own session, not fall back to a pid")
        #expect(text.contains("bash"), "the tool name is a label, not content")
        // And the added spellings did not open the door to content.
        #expect(!text.contains("id_rsa"), "tool arguments are not ours to keep")
        #expect(!text.contains("the user's own words"), "prompt text is not ours to keep")
    }

    @Test("a burst cannot grow the spool without bound")
    func capHolds() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let overflow = EventSpool.maximumEvents + 5
        for index in 0..<overflow {
            EventSpool.write(envelope("PreToolUse", at: TimeInterval(index)), to: directory)
        }
        #expect(EventSpool.pendingCount(in: directory) == EventSpool.maximumEvents)

        // What was dropped is the oldest, not the newest: the newest events
        // are the ones that describe what the sessions are doing now.
        var replayed: [BridgeEnvelope] = []
        EventSpool.drain(from: directory) { replayed.append($0) }
        #expect(replayed.first?.receivedAt == origin.addingTimeInterval(5))
        #expect(replayed.last?.receivedAt == origin.addingTimeInterval(TimeInterval(overflow - 1)))
    }

    @Test("events replay oldest first, whatever order the files suggest")
    func replayIsChronological() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Written by hand with names that lie about their order, which is what
        // a clock change or a file copied in by hand would look like. The
        // envelopes' own timestamps are the ones that decide.
        func write(_ envelope: BridgeEnvelope, as name: String) throws {
            let data = try envelope.encoded()
            try data.write(to: directory.appendingPathComponent(name))
        }
        try write(envelope("Stop", at: 9), as: "0000000000000009-zzz.json")
        try write(envelope("UserPromptSubmit", at: 1), as: "0000000000009999-aaa.json")

        var order: [String] = []
        EventSpool.drain(from: directory) { order.append($0.eventName) }
        #expect(order == ["UserPromptSubmit", "Stop"],
                "a session's events must not be replayed backwards")
    }

    @Test("an unreadable file is discarded rather than replayed forever")
    func unreadableFileIsCleared() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        try Data("this is not an envelope".utf8)
            .write(to: directory.appendingPathComponent("0000000000000001-broken.json"))
        EventSpool.write(envelope("Stop", at: 2), to: directory)

        var replayed: [BridgeEnvelope] = []
        let count = EventSpool.drain(from: directory) { replayed.append($0) }
        #expect(count == 1)
        #expect(replayed.first?.eventName == "Stop")
        #expect(EventSpool.pendingCount(in: directory) == 0)
    }

    @Test("the files are owner-only and the directory is private")
    func permissionsAreTight() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        EventSpool.write(envelope("Stop"), to: directory)
        let name = try #require(
            try FileManager.default.contentsOfDirectory(atPath: directory.path).first
        )
        let attributes = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent(name).path
        )
        let fileMode = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(fileMode.intValue == 0o600, "spooled events are not for other accounts")
    }

    @Test("a payload that is not JSON still maps, on its event name alone")
    func nonJSONPayload() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let raw = BridgeEnvelope(
            agentID: "claude-code",
            eventName: "Stop",
            receivedAt: origin,
            proc: BridgeProcessInfo(pid: 7, ppid: 6, tty: nil),
            rawPayload: Data("not json at all".utf8)
        )
        EventSpool.write(raw, to: directory)

        var replayed: [BridgeEnvelope] = []
        EventSpool.drain(from: directory) { replayed.append($0) }
        let envelope = try #require(replayed.first)
        let event = try #require(
            EventNormalizer(profiles: AgentProfiles.all).normalize(envelope).first
        )
        #expect(event.kind == .completed)
        #expect(event.sessionID == "ppid-6", "with no session id, the parent process is the session")
    }

    @Test("draining an empty or missing spool is a no-op")
    func emptyDrain() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(EventSpool.drain(from: directory) { _ in } == 0)
        #expect(EventSpool.pendingCount(
            in: directory.appendingPathComponent("never-created")
        ) == 0)
    }
}
