import Foundation

/// The TypeScript both extension-file integrations install.
///
/// Pi and Oh My Pi share the extension API — omp is Pi rebranded — but not the
/// events the pet needs; those events, the agent's id, its ownership marker and
/// the cost note are what vary between the two generated files:
///
/// | what it is for | Pi 0.85 | Oh My Pi 18 |
/// |---|---|---|
/// | "blocked on you" | `ui_prompt_start` (its own prompt is on screen) | `tool_approval_requested` / the `ask` tool |
/// | a finished turn | `agent_settled` | `agent_end`, minus the ones carrying `willContinue` |
///
/// A plain `agent_end` is not a settle on Pi (an auto-retry or a queued
/// follow-up may still run), and `agent_settled` does not exist on omp at all
/// (checked against 18.1.22), so one file cannot be right for both. Everything
/// else is shared: the shim invocation, the session id, the reduced context
/// reading, and the environment payload channel.
public enum ExtensionTemplate {

    /// Which events the agent's runtime actually fires.
    public enum EventSet: Sendable {
        case pi
        case ohMyPi
    }

    /// The line naming the shim and the agent a generated file reports to.
    ///
    /// Written into the file and recorded verbatim in the `IntegrationRecord`,
    /// so presence and removal are one question: is every recorded line still
    /// there? Comment-safe, because this line is a comment and a path can
    /// contain a line separator.
    public static func markerLine(agentID: String, shimPath: String) -> String {
        "// shim: \(commentSafe(shimPath)) --agent \(commentSafe(agentID))"
    }

    /// The path as it may appear inside a `//` comment line.
    ///
    /// A path can contain a line separator (legal on APFS), and one inside a
    /// comment ends it — the rest of the path is then parsed as code and the
    /// file does not load, while the record still claims it is present, so
    /// nothing reports it. The recorded marker line goes through the same
    /// transformation, or removal would stop matching the file it wrote.
    public static func commentSafe(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: " ")
            .replacingOccurrences(of: "\u{2029}", with: " ")
    }

    /// A JavaScript string literal, quoted and escaped.
    ///
    /// Paths are the only thing here that comes from outside, and a path can
    /// legally contain a quote or a backslash. Building the literal by
    /// concatenation is how a path with an apostrophe silently breaks a
    /// generated file; escaping is how it does not. Quotes included, because
    /// callers also use this to ask "is the recorded path still in the file?".
    public static func jsStringLiteral(_ value: String) -> String {
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

    /// The whole file: a marker line, the shim call, and the handlers for
    /// `events`.
    ///
    /// Plain JavaScript (valid TypeScript), node built-ins only, and fire and
    /// forget — the same contract the hooks keep. The pet missing an event is
    /// invisible; an extension that stalls the agent is not.
    public static func source(
        agentID: String,
        shimPath: String,
        events: EventSet,
        marker: String
    ) -> String {
        let shim = jsStringLiteral(shimPath)
        let agent = jsStringLiteral(agentID)

        return """
        \(marker)
        \(markerLine(agentID: agentID, shimPath: shimPath))
        //
        // Remove with:  AgentPet --unconfigure \(agentID)
        //               (or the manager window's Remove Integration)
        //
        // What it does: reports session state to the desktop pet by spawning
        // the runtime's hook shim, once per event, with a small JSON payload in
        // the environment — the session id, the working directory, and, on the
        // tool events that carry one, the tool's name — plus one reduced
        // context reading per finished turn. Prompts, tool arguments, tool
        // output, and model output are never read, and nothing is written
        // anywhere.
        //
        \(costNote(for: events))
        //
        // It is deliberately a report and never a gate. Every step is wrapped
        // so a failure cannot reach the agent, the child is detached and
        // unref'd so it can neither hold up a turn nor outlive the session,
        // and it is told to touch nothing but its own arguments and the one
        // environment variable carrying this event.

        import { spawn } from "node:child_process";
        import { basename } from "node:path";

        const SHIM = \(shim);
        const AGENT = \(agent);

        // The session id is what the pet draws a row from, so it has to be the
        // same for every event of one session and different between sessions.
        // The session manager's id is preferred (the bare one, not the session
        // file's `<timestamp>_<id>` name); a session that has not been persisted
        // yet falls back to its file's name, and a sessionless process to its
        // pid, rather than sharing a row with every other session.
        function sessionIdFor(ctx) {
          try {
            const id = ctx && ctx.sessionManager ? ctx.sessionManager.getSessionId() : null;
            if (id) return String(id);
            const file = ctx && ctx.sessionManager && ctx.sessionManager.getSessionFile
              ? ctx.sessionManager.getSessionFile()
              : null;
            if (file) {
              const name = basename(String(file));
              return name.endsWith(".jsonl") ? name.slice(0, -6) : name;
            }
          } catch {}
          return "pid-" + process.pid;
        }

        function send(event, payload) {
          try {
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

        function report(event, ctx, toolName) {
          try {
            const payload = { session_id: sessionIdFor(ctx), cwd: (ctx && ctx.cwd) || "" };
            if (toolName) payload.toolName = String(toolName);
            send(event, payload);
          } catch {}
        }

        // The same reduced shape the status-line taps deliver: session id,
        // percentage, window, tokens, model. Nothing else leaves this process.
        function contextPayload(ctx) {
          try {
            const usage = ctx.getContextUsage ? ctx.getContextUsage() : null;
            const tokens = usage && usage.tokens;
            if (typeof tokens !== "number") return null;
            const model = ctx.model;
            const window = model && model.contextWindow;
            const payload = {
              session_id: sessionIdFor(ctx),
              tokens: Math.round(tokens),
              model: model ? (model.name || model.id) : undefined,
            };
            if (typeof window === "number" && window > 0) {
              payload.window = window;
              payload.used_percentage = Math.round((tokens / window) * 1000) / 10;
            }
            return payload;
          } catch {
            return null;
          }
        }

        function reportContext(ctx) {
          const context = contextPayload(ctx);
          if (context) send("context_update", context);
        }

        export default function (pi) {
          pi.on("session_start", (_event, ctx) => report("session_start", ctx));
          pi.on("agent_start", (_event, ctx) => report("agent_start", ctx));
          pi.on("session_shutdown", (_event, ctx) => report("session_shutdown", ctx));

          // One event per tool, so the panel can name the tool being used. The
          // shim always exits 0 and this handler returns nothing: neither can
          // change what the agent does.
          pi.on("tool_execution_start", (event, ctx) =>
            report("tool_execution_start", ctx, event && event.toolName));
        \(registrations(events))
        }
        """
    }

    /// What the installed file costs, stated where the user can read it.
    ///
    /// Not shared between the two: the cost belongs to the agent that charges
    /// it, and a note that described one of them in the other's file would be
    /// false twice over (omp's gate is on tool-lifecycle handlers, which the Pi
    /// file does not register, and Pi has no speculative execution to lose).
    static func costNote(for events: EventSet) -> String {
        switch events {
        case .ohMyPi:
            return """
    // What it costs: omp will not run its experimental speculative local reads
    // (settings: tools.speculativeExecution.enabled, off by default) while any
    // extension has a handler on one of the four tool-lifecycle events —
    // tool_call, tool_result, tool_approval_requested, tool_approval_resolved
    // (src/speculation/host.ts). This file takes the last two, which is how an
    // approval shows up as "Needs input". Uninstalling restores speculation.
    """
        case .pi:
            return """
    // What it costs: nothing. This file takes no tool_call, tool_result, or
    // approval event and rewrites no argument, so the agent runs exactly as it
    // would without it.
    """
        }
    }

    /// The handlers that differ between the two event sets.
    private static func registrations(_ events: EventSet) -> String {
        switch events {
        case .pi:
            return """
              // Pi raises this while one of its own prompts — a permission
              // gate, a picker — is on screen: the one "it is waiting for you"
              // signal the extension can draw from.
              pi.on("ui_prompt_start", (_event, ctx) => report("ui_prompt_start", ctx));

              // agent_settled, not agent_end: after agent_end Pi may still run an
              // auto-retry or a queued follow-up, so a plain agent_end is not a
              // finished turn.
              pi.on("agent_settled", (_event, ctx) => {
                report("agent_settled", ctx);
                reportContext(ctx);
              });
            """
        case .ohMyPi:
            return """
              pi.on("tool_execution_end", (_event, ctx) => report("tool_execution_end", ctx));

              // The approval gate: the tool is held until the user answers.
              pi.on("tool_approval_requested", (event, ctx) =>
                report("tool_approval_requested", ctx, event && event.toolName));
              pi.on("tool_approval_resolved", (event, ctx) =>
                report("tool_approval_resolved", ctx, event && event.toolName));

              // `willContinue` means a retry is already scheduled, so this is not
              // the user-visible end of the turn — and omp has no agent_settled to
              // prefer (checked against 18.1.22).
              pi.on("agent_end", (event, ctx) => {
                if (!event || !event.willContinue) {
                  report("agent_end", ctx);
                  reportContext(ctx);
                }
              });
            """
        }
    }
}
