import Foundation
import Testing
@testable import AgentPetCore

private let ompEventEpoch = Date(timeIntervalSince1970: 1_700_000_000)
private let aShimPath = "/Applications/AgentPet.app/Contents/MacOS/agentpet-hook"

/// The payload the installed extension writes: a session id, the working
/// directory, and a tool name where one applies. Nothing else is ever sent.
private func ompEnvelope(event: String, extra: String = "") -> BridgeEnvelope {
    BridgeEnvelope(
        agentID: "omp",
        eventName: event,
        receivedAt: ompEventEpoch,
        proc: BridgeProcessInfo(pid: 2, ppid: 1, tty: "/dev/ttys004"),
        rawPayload: Data(#"{"session_id":"s1","cwd":"/tmp/proj""#.utf8)
            + Data(extra.utf8)
            + Data("}".utf8)
    )
}

@Suite("Oh My Pi normalization")
struct OhMyPiNormalizationTests {

    private let normalizer = EventNormalizer(profiles: AgentProfiles.all)

    @Test("the events the extension reports map to the states they mean", arguments: [
        (event: "session_start", extra: "", expected: AgentEventKind.sessionStarted),
        (event: "agent_start", extra: "", expected: .working),
        (event: "tool_execution_start", extra: #","toolName":"bash""#, expected: .working),
        (event: "tool_execution_end", extra: #","toolName":"bash""#, expected: .working),
        (event: "tool_approval_requested", extra: #","toolName":"write""#, expected: .waitingApproval),
        (event: "tool_approval_resolved", extra: #","toolName":"write""#, expected: .working),
        (event: "agent_end", extra: "", expected: .completed),
        (event: "session_shutdown", extra: "", expected: .sessionClosed),
    ])
    func eventMapping(event: String, extra: String, expected: AgentEventKind) {
        let events = normalizer.normalize(ompEnvelope(event: event, extra: extra))
        #expect(events.first?.kind == expected,
                "\(event) produced \(String(describing: events.first?.kind))")
    }

    @Test("every event registered in the file has a rule in the profile")
    func registeredEventsAreKnown() {
        // The counterpart of the Claude Code check: an event that is reported
        // but not normalized is a process spawned per occurrence for a state
        // change that cannot happen.
        let source = AgentPetExtension.source(agentID: "omp", shimPath: aShimPath)
        let profile = AgentProfiles.profile(for: "omp")
        let known = Set((profile?.rules ?? []).flatMap(\.matches))

        // Every event the file listens for is one the profile knows.
        for event in AgentPetExtension.listenedEvents {
            #expect(source.contains("pi.on(\"\(event)\""), "\(event) is listed but never registered")
        }
        // And every event it *sends* has a rule, including the context reading
        // that rides out of the settle handler.
        for event in AgentPetExtension.reportedEvents {
            #expect(known.contains(event), "\(event) is reported but no rule mentions it")
        }

        // Nothing is registered behind the list's back.
        let registered = listenedEvents(inGeneratedFile: source)
        #expect(registered == Set(AgentPetExtension.listenedEvents), "registered: \(registered.sorted())")
    }

    @Test("the keys the file writes are the keys the profile reads")
    func payloadKeysMatchTheProfile() throws {
        // The file and the profile are written separately, and a rename in one
        // degrades every event to a pid-derived session without any test
        // noticing. Both of the file's payload builders are checked, not the
        // whole source: `session_id` appears in each of them, so a rename in
        // one would otherwise be covered for by the other.
        let source = AgentPetExtension.source(agentID: "omp", shimPath: aShimPath)
        let profile = try #require(AgentProfiles.profile(for: "omp"))

        func region(from start: String, to end: String) throws -> String {
            let lower = try #require(source.range(of: start)?.lowerBound)
            let upper = try #require(source.range(of: end)?.lowerBound)
            return String(source[lower..<upper])
        }

        let lifecycle = try region(
            from: "function report(event, ctx, toolName) {",
            to: "// The same reduced shape"
        )
        let context = try region(
            from: "function contextPayload(ctx) {",
            to: "function reportContext(ctx) {"
        )

        let fields = Set(
            profile.rules
                .flatMap { [$0.sessionIDField, $0.workingDirectoryField, $0.toolNameField] }
                .compactMap { $0 }
        )
        #expect(fields.isSubset(of: ["session_id", "cwd", "toolName"]),
                "the profile reads a name the file does not write: \(fields.sorted())")
        // And the other direction: the names are in the payload that carries them.
        #expect(lifecycle.contains("session_id:") && context.contains("session_id:"),
                "a payload stopped naming the session the way the profile reads it")
        #expect(lifecycle.contains("cwd:"), "the lifecycle payload stopped naming the working directory")
        #expect(lifecycle.contains("payload.toolName"),
                "the lifecycle payload stopped naming the tool")
    }

    @Test("the ask tool is the one tool that means the agent is blocked on you")
    func askToolWaits() {
        let asking = normalizer.normalize(ompEnvelope(
            event: "tool_execution_start", extra: #","toolName":"ask""#
        ))
        #expect(asking.first?.kind == .waitingInput)
        #expect(asking.first?.toolName == "ask",
                "the panel names the tool an approval or a question is for")

        // Any other tool is work, and the order of the rules is what decides
        // that — the narrow rule has to come first.
        let running = normalizer.normalize(ompEnvelope(
            event: "tool_execution_start", extra: #","toolName":"bash""#
        ))
        #expect(running.first?.kind == .working)
    }

    @Test("a tool event with no tool name is still work, not a wait")
    func missingToolNameIsWork() {
        let events = normalizer.normalize(ompEnvelope(event: "tool_execution_start"))
        #expect(events.first?.kind == .working)
    }

    @Test("an approval names the tool it is holding up")
    func approvalNamesTheTool() {
        let events = normalizer.normalize(ompEnvelope(
            event: "tool_approval_requested", extra: #","toolName":"write""#
        ))
        #expect(events.first?.kind == .waitingApproval)
        #expect(events.first?.toolName == "write")
    }

    @Test("session id and working directory are extracted from the extension's payload")
    func fieldExtraction() {
        let events = normalizer.normalize(ompEnvelope(event: "agent_start"))
        #expect(events.first?.sessionID == "s1")
        #expect(events.first?.focusTarget?.path == "/tmp/proj")
        #expect(events.first?.confidence.source == "omp.hook.agent_start")
    }

    @Test("an event no rule covers changes nothing")
    func unmappedEventIgnored() {
        // `turn_end` and the message events are deliberately unmapped: omp's
        // turn is one model call, so a turn boundary is not a finished prompt.
        for event in ["turn_end", "message_end", "session_compact"] {
            #expect(normalizer.normalize(ompEnvelope(event: event)).isEmpty, "\(event)")
        }
    }

    @Test("a session id the extension could not read falls back to the process")
    func fallbackSessionUsesParentProcess() {
        let envelope = BridgeEnvelope(
            agentID: "omp",
            eventName: "agent_start",
            receivedAt: ompEventEpoch,
            proc: BridgeProcessInfo(pid: 500, ppid: 4242, tty: nil),
            rawPayload: Data("{}".utf8)
        )
        #expect(normalizer.normalize(envelope).first?.sessionID == "ppid-4242")
    }

    @Test("every rule that reads a tool name also says where to read it from")
    func toolNameConditionsHaveAField() {
        // A `whenToolName` with no field to read it from can never match, which
        // would silently turn the ask-tool rule into a rule that never fires.
        for profile in AgentProfiles.all {
            for rule in profile.rules where rule.whenToolName != nil {
                #expect(rule.toolNameField != nil,
                        "\(profile.agentID) constrains a tool name it never reads")
            }
        }
    }
}

@Suite("Oh My Pi registry entry")
struct OhMyPiRegistryTests {

    private var transaction: ConfigTransaction {
        ConfigTransaction(backupDirectory: URL(fileURLWithPath: "/tmp/agentpet-omp-registry-test"))
    }

    @Test("the agent is registered as detected and configurable")
    func registered() throws {
        let profile = try #require(
            AgentIntegrationRegistry.profile(for: "omp", transaction: transaction)
        )
        #expect(profile.displayName == "Oh My Pi")
        #expect(profile.configurator != nil)
        #expect(profile.capabilities.contains(.configure))
        #expect(profile.capabilities.contains(.uninstall))
        #expect(profile.configurationNote == nil, "a configurable agent has nothing to explain")
    }

    @Test("the integration is a file the runtime owns, and says so")
    func mechanismIsExtension() throws {
        let profile = try #require(
            AgentIntegrationRegistry.profile(for: "omp", transaction: transaction)
        )
        // The card's and --status's wording follows from this.
        #expect(profile.mechanism == .extensionFile)
        let configurator = try #require(profile.configurator as? ExtensionFileConfigurator)
        #expect(configurator.fileURL.lastPathComponent == AgentPetExtension.fileName)
        #expect(configurator.fileURL.deletingLastPathComponent().lastPathComponent == "extensions")
    }

    @Test("detection looks for the omp executable and its agent directory")
    func detectionSpec() throws {
        let profile = try #require(
            AgentIntegrationRegistry.profile(for: "omp", transaction: transaction)
        )
        #expect(profile.detection.executableNames == ["omp"])
        // `~/.bun/bin`, where a bun-installed omp lives, is already among the
        // detector's fallback paths — see AgentDetector.versionManagerPaths.
        #expect(profile.detection.extraSearchPaths.isEmpty)
        #expect(profile.detection.configFiles.allSatisfy { $0.path.contains(".omp/agent") })
    }

    @Test("the shipped extension text is stable enough to diff")
    func sourceIsDeterministic() {
        // The configurator writes this text and later compares the file to it
        // to decide that nothing changed, so it cannot be a function of time,
        // locale, or process state.
        let first = AgentPetExtension.source(agentID: "omp", shimPath: aShimPath)
        let second = AgentPetExtension.source(agentID: "omp", shimPath: aShimPath)
        #expect(first == second)
        #expect(first.contains("\n"), "source with no newlines is not a file")
    }
}
