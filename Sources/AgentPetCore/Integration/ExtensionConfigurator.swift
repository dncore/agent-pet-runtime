import Foundation

/// The extension file the runtime installs into an agent that is extended by
/// dropping one file into a directory, rather than by editing a table in a
/// configuration file.
///
/// Oh My Pi is the first of these: it loads every `*.ts` in
/// `~/.omp/agent/extensions/` at session start, so the integration is a file
/// rather than an edit — which makes install a write and removal a delete, and
/// makes "did we write this?" a question about the file's own contents.
///
/// Generated in code rather than shipped as a resource, for the same reason
/// `HookSetup` assembles Claude Code's hooks in code: the exact text can be
/// asserted in tests and read without installing anything.
public enum AgentPetExtension {

    /// The name the runtime installs under. One file per extension, so the
    /// name *is* the identity — a second copy would be a second extension.
    public static let fileName = "agentpet.ts"

    /// A line present in every file the runtime writes, and therefore the only
    /// evidence it accepts that such a file is its own before replacing it.
    /// Removal asks a different question — whether the file still carries the
    /// `// shim:` line the *record* holds — so a file that lost that line is
    /// left alone even though this marker still identifies it. Stable across
    /// versions on purpose: the shim line below moves when the app does, and a
    /// file written by an older build still has to be recognisable as ours.
    public static let ownershipMarker = "// agentpet-runtime extension"

    /// The line naming the shim and the agent this copy reports to.
    ///
    /// Recorded verbatim in the `IntegrationRecord`, so removal matches on
    /// content rather than on a rule — the same contract the hook lines have,
    /// and what lets an install made by a since-moved runtime still be
    /// recognised (and replaced) later.
    public static func markerLine(agentID: String, shimPath: String) -> String {
        "// shim: \(shimPath) --agent \(agentID)"
    }

    /// Whether a file's text is one of ours.
    public static func owns(_ text: String) -> Bool {
        text.contains(ownershipMarker)
    }

    /// Every event the installed extension reports.
    ///
    /// Kept here — rather than only inside the generated source — so a test can
    /// prove the two agree, and that the normalizer has a rule for each of
    /// them. An event with no rule would be a process spawned per occurrence
    /// for a state change that cannot happen.
    public static let reportedEvents = [
        "session_start",
        "agent_start",
        "tool_execution_start",
        "tool_execution_end",
        "tool_approval_requested",
        "tool_approval_resolved",
        "agent_end",
        "session_shutdown",
    ]

    /// The extension's source.
    ///
    /// Every handler reports and returns nothing. That is the whole safety
    /// argument: omp runs extension handlers in-process, `tool_call` handlers
    /// fail *closed* (a throw blocks the tool), and a pet that changed what the
    /// agent does would be a far worse bug than one that misses an event. So
    /// no handler here is registered for an event that can block, the two
    /// registrations that do have a cost are called out in the file itself,
    /// and every step is wrapped so a failure cannot reach the agent.
    public static func source(agentID: String, shimPath: String) -> String {
        """
        \(ownershipMarker) — installed by Agent Pet Runtime.
        \(markerLine(agentID: agentID, shimPath: shimPath))
        //
        // Remove with:  AgentPet --unconfigure \(agentID)
        //               (or the manager window's Remove Integration)
        //
        // What it does: reports session state to the desktop pet by spawning
        // the runtime's hook shim, once per event, with a small JSON payload in
        // the environment — the session id, the working directory, and, on the
        // tool events that carry one, the tool's name. Prompts, tool arguments,
        // tool output, and model output are never read, and nothing is written
        // anywhere.
        //
        // What it costs: omp will not run its experimental speculative local
        // reads (settings: tools.speculativeExecution.enabled, off by default)
        // while any extension has a handler on one of the four tool-lifecycle
        // events — tool_call, tool_result, tool_approval_requested,
        // tool_approval_resolved (src/speculation/host.ts). This file takes the
        // last two, which is how an approval shows up as "Needs input".
        // Uninstalling restores speculation. Nothing else about the agent
        // changes: no handler returns a value, so no tool call is blocked,
        // rewritten, or approved by this file.
        //
        // It is deliberately a report and never a gate. Every step is wrapped
        // so a failure cannot reach the agent, the child is detached and
        // unref'd so it can neither hold up a turn nor outlive the session,
        // and it is told to touch nothing but its own arguments and the one
        // environment variable carrying this event.

        import { spawn } from "node:child_process";
        import { basename } from "node:path";

        // Written by the runtime; the second line is the marker it looks for
        // when you ask it to remove the integration.
        const SHIM = \(jsStringLiteral(shimPath));
        const AGENT = \(jsStringLiteral(agentID));

        // The session id is what the pet draws a row from, so it has to be the
        // same for every event of one session and different between sessions.
        // The session manager knows it; a session that has not been persisted
        // yet still has one, and a sessionless process falls back to its pid
        // rather than sharing a row with every other session.
        function sessionIdFor(ctx) {
          try {
            const id = ctx && ctx.sessionManager ? ctx.sessionManager.getSessionId() : null;
            if (id) return String(id);
            const file = ctx && ctx.sessionManager ? ctx.sessionManager.getSessionFile() : null;
            if (file) {
              const name = basename(String(file));
              return name.endsWith(".jsonl") ? name.slice(0, -6) : name;
            }
          } catch {}
          return "pid-" + process.pid;
        }

        function report(event, ctx, toolName) {
          try {
            const payload = { sessionId: sessionIdFor(ctx), cwd: (ctx && ctx.cwd) || "" };
            if (toolName) payload.toolName = String(toolName);

            // The payload goes through the environment, not stdin. This code
            // runs inside the agent's own runtime, where a write to a pipe is
            // queued on an event loop the agent may be holding: measured, a
            // busy stretch of 30ms between spawning the shim and writing to it
            // is enough for the shim to give up waiting and report the event
            // with no session at all. The environment is delivered at spawn
            // time by the kernel, so there is nothing to be late for.
            const env = { ...process.env };
            env.AGENTPET_PAYLOAD_BASE64 = Buffer.from(JSON.stringify(payload), "utf8").toString("base64");

            const child = spawn(SHIM, ["--agent", AGENT, "--event", event], {
              // The shim never prints, and this process runs inside a terminal
              // the agent is drawing: nothing it says may reach that terminal.
              stdio: ["ignore", "ignore", "ignore"],
              detached: true,
              env,
            });
            child.on("error", () => {});
            child.unref();
          } catch {}
        }

        export default function (pi) {
          pi.on("session_start", (_event, ctx) => report("session_start", ctx));
          pi.on("agent_start", (_event, ctx) => report("agent_start", ctx));

          // One event per tool, so the panel can name the tool being used. The
          // shim always exits 0 and this handler returns nothing: neither can
          // change what the agent does.
          pi.on("tool_execution_start", (event, ctx) =>
            report("tool_execution_start", ctx, event && event.toolName));
          pi.on("tool_execution_end", (_event, ctx) => report("tool_execution_end", ctx));

          // The approval gate is the counterpart of a permission prompt: the
          // tool is held until the user answers.
          pi.on("tool_approval_requested", (event, ctx) =>
            report("tool_approval_requested", ctx, event && event.toolName));
          pi.on("tool_approval_resolved", (event, ctx) =>
            report("tool_approval_resolved", ctx, event && event.toolName));

          // `willContinue` means the session has already scheduled a retry, so
          // this is not the user-visible end of the turn — reporting it would
          // have the pet announce completion in the middle of the job.
          pi.on("agent_end", (event, ctx) => {
            if (!event || !event.willContinue) report("agent_end", ctx);
          });

          pi.on("session_shutdown", (_event, ctx) => report("session_shutdown", ctx));
        }
        """
    }

    /// A JavaScript string literal, escaped rather than interpolated.
    ///
    /// Paths are the only thing here that comes from outside, and a path can
    /// legally contain a quote or a backslash. Building the literal by
    /// concatenation is how a path with an apostrophe silently breaks a
    /// generated file; escaping is how it does not.
    static func jsStringLiteral(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// Installs the runtime's extension for agents whose integration is one file
/// in an extensions directory.
///
/// The JSON transaction cannot do this — its whole job is editing a table
/// inside a file somebody else owns, and this file is *ours*, whole. What it
/// keeps is the discipline: snapshot, back up before changing anything,
/// write atomically, read back and prove the result, and never touch a file
/// that is not ours.
public struct ExtensionFileConfigurator: AgentConfigurator {

    public let agentID: String
    /// The directory the agent scans, e.g. `~/.omp/agent/extensions`.
    public let directory: URL
    public let fileName: String
    private let transaction: ConfigTransaction

    public init(
        agentID: String,
        directory: URL,
        fileName: String = AgentPetExtension.fileName,
        transaction: ConfigTransaction
    ) {
        self.agentID = agentID
        self.directory = directory
        self.fileName = fileName
        self.transaction = transaction
    }

    public var fileURL: URL { directory.appendingPathComponent(fileName) }

    public func configurationTargets() -> [URL] { [fileURL] }

    /// True when the file exists and still carries every line the record says
    /// the runtime wrote into it — the shim line included, so a file whose
    /// marker line was rewritten (by hand, or by a later Configure with a
    /// different shim path) is reported as disconnected until Configure runs
    /// again. A moved app is deliberately *not* one of these cases: nothing
    /// compares the path in the record with the path in use, and the record and
    /// the file are written together, so they agree until something rewrites
    /// one of them.
    public func entriesPresent(in record: IntegrationRecord) -> Bool {
        guard !record.entries.isEmpty else { return false }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return false }
        return record.entries.allSatisfy { text.contains($0.command) }
    }

    public func configure(
        shimPath: String,
        replacing previous: IntegrationRecord?,
        now: Date
    ) throws -> ConfigurationOutcome {

        let source = AgentPetExtension.source(agentID: agentID, shimPath: shimPath)
        let entry = WrittenEntry(
            file: fileURL.path,
            event: fileName,
            command: AgentPetExtension.markerLine(agentID: agentID, shimPath: shimPath)
        )

        let record = IntegrationRecord(
            agentID: agentID,
            status: .configured,
            configuredAt: previous?.configuredAt ?? now,
            lastValidatedAt: now,
            shimPath: shimPath,
            entries: [entry]
        )

        let existing = try transaction.snapshot(fileURL)
        let existingText: String? = existing.existed
            ? String(data: existing.contents, encoding: .utf8)
            : nil

        // A file we did not write is somebody's extension — and one we cannot
        // even read as text certainly is. Refusing beats overwriting either.
        if existing.existed, !(existingText.map(AgentPetExtension.owns) ?? false) {
            throw ConfigurationError.foreignFile(fileURL.path)
        }

        // Idempotent: a second Configure with the same shim path changes
        // nothing at all, not even a rewrite.
        if existingText == source {
            return ConfigurationOutcome(record: record, changedFiles: [], backupURLs: [])
        }

        var backups: [String] = []
        if let backup = try backup(existing) { backups.append(backup.path) }

        do {
            try transaction.writeAtomically(Data(source.utf8), to: fileURL)
        } catch {
            throw ConfigurationError.transactionFailed(
                "could not write \(fileURL.path): \(error)"
            )
        }

        // Read back and prove both that the bytes are what we generated and
        // that the file still identifies itself as ours.
        guard let written = try? String(contentsOf: fileURL, encoding: .utf8), written == source else {
            try? transaction.rollback(to: existing)
            throw ConfigurationError.transactionFailed(
                "\(fileURL.path) did not match what was written; the previous state was restored"
            )
        }

        return ConfigurationOutcome(record: record, changedFiles: [fileURL.path], backupURLs: backups)
    }

    public func uninstall(_ record: IntegrationRecord, now: Date) throws -> ConfigurationOutcome {
        let updated = IntegrationRecord(
            agentID: agentID,
            status: .notConfigured,
            configuredAt: record.configuredAt,
            lastValidatedAt: now,
            shimPath: record.shimPath,
            entries: []
        )

        let snapshot = try transaction.snapshot(fileURL)
        guard snapshot.existed,
              let text = String(data: snapshot.contents, encoding: .utf8),
              !record.entries.isEmpty,
              record.entries.allSatisfy({ text.contains($0.command) })
        else {
            // Already gone, or replaced by hand: there is nothing of ours left
            // to remove, and that is not a failure.
            return ConfigurationOutcome(record: updated, changedFiles: [], backupURLs: [])
        }

        // Kept even though the file is ours: a backup is what makes deleting a
        // file reversible, and the user may have added to it since.
        var backups: [String] = []
        if let backup = try backup(snapshot) { backups.append(backup.path) }

        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw ConfigurationError.transactionFailed(
                "could not remove \(fileURL.path): \(error)"
            )
        }

        // The directory itself is left alone: the agent scans it, an empty
        // extensions directory means "no extensions", and it may predate us.
        return ConfigurationOutcome(record: updated, changedFiles: [fileURL.path], backupURLs: backups)
    }

    /// A copy of the file as it was, before it is replaced or deleted.
    ///
    /// Through the same backup directory and naming as every other edit the
    /// runtime makes, so one cleanup policy covers them all.
    private func backup(_ snapshot: ConfigSnapshot) throws -> URL? {
        guard snapshot.existed else { return nil }
        return try transaction.backUp(snapshot)
    }
}
