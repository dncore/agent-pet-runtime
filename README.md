<p align="center">
  <img src="Resources/AppIcon-512.png" width="132" alt="Agent Pet Runtime: a round-faced pet inside a golden ring, on orange">
</p>

# Agent Pet Runtime

**English** · [简体中文](README.zh-CN.md)

A macOS desktop pet that reacts to what your CLI coding agents are doing.

Claude Code hits a permission prompt and the pet raises a paw. A task finishes
and it celebrates, then goes back to idling. Move it around and it walks the way
you drag it. Leave it alone and it looks at your cursor, in sixteen directions.

It is not a toy bolted onto a log parser. Agent state is modelled properly, the
bridge is measured and bounded, and nothing is recorded that should not be.

```
   Claude Code ─┐
   Codex       ─┤          spawns          ┌──────────────┐
   Grok        ─┼──────► agentpet-hook ───►│    socket    │
   Pi          ─┤          (~5 ms)         └──────┬───────┘
   Oh My Pi    ─┘                                 │
                                                  │
                       ┌──────────────────────────▼──────────────────────┐
                       │  normalize → activity engine → animation → pet  │
                       └─────────────────────────────────────────────────┘
```

---

## Install

```bash
brew tap dncore/agent-pet-runtime
brew install --cask dncore/agent-pet-runtime/agent-pet-runtime
```

The name on the second line is spelled in full on purpose. Homebrew treats a
third-party tap as untrusted until it is told otherwise, and refuses to load a
cask out of one: `brew install --cask agent-pet-runtime` stops with

```
Error: Refusing to load cask dncore/agent-pet-runtime/agent-pet-runtime from untrusted tap dncore/agent-pet-runtime.
```

The fully qualified name is Homebrew's own way past that — asking for
`tap/name` trusts the cask it was asked for, and says so. `brew trust
dncore/agent-pet-runtime` does the same for the whole tap if you would rather
(`brew trust --help`, and https://docs.brew.sh/Tap-Trust).

The app is ad-hoc signed rather than notarised. A copy that macOS quarantined —
one downloaded through a browser, or dragged out of the zip in Finder — is
reported by Gatekeeper as damaged; a `brew install` is not quarantined in the
first place. If it does object:

```bash
xattr -dr com.apple.quarantine "/Applications/AgentPet.app"
```

<details>
<summary>Or build from source</summary>

```bash
git clone https://github.com/dncore/agent-pet-runtime.git
cd agent-pet-runtime
swift build -c release
./Scripts/build-app.sh          # assembles AgentPet.app
open build/AgentPet.app
```

Requires macOS 14+ and Swift 6.1+ (Xcode 16.4 or newer).

</details>

The cask is generated from
[`homebrew/agent-pet-runtime.rb.template`](homebrew/agent-pet-runtime.rb.template)
on every release and pushed to
[dncore/homebrew-agent-pet-runtime](https://github.com/dncore/homebrew-agent-pet-runtime).
Edit the template here, not the tap.

---

## Connecting your agents

Nothing is configured until you say so. Either use the menu bar, or:

```bash
swift run AgentPet --status                    # what is installed and configured
swift run AgentPet --configure claude-code     # install the hooks
swift run AgentPet --unconfigure claude-code   # remove exactly what it wrote
```

**No restart is required.** Claude Code re-reads `~/.claude/settings.json` on
every hook dispatch, so hooks added mid-session take effect on the next event.
Sessions running long jobs are not interrupted. (Verified by adding
`SubagentStart`/`SubagentStop` to a session that had been running for hours and
watching them fire.)

All six agents are configurable today. Codex's hooks carry one extra step:
Codex skips a hook until you review and trust it in Codex's own `/hooks`
panel, and the runtime says so — and nothing else about the pet — the moment
it configures them.

### What configuring does

What configuring does depends on the agent; nothing else is touched. Claude
Code gets hook lines in `~/.claude/settings.json`. Grok gets
`~/.grok/hooks/agentpet.json` — the runtime's own file, deleted on removal —
plus one appended switch, `[compat.claude] hooks = false` in
`~/.grok/config.toml`, which stops Grok's Claude-compatibility scan from
firing the Claude hooks a second time. Pi gets one TypeScript extension of the
runtime's own, `~/.pi/agent/extensions/agentpet.ts`, also deleted on removal.
Oh My Pi gets the same shape of file at
`~/.omp/agent/extensions/agentpet.ts` — one extension the runtime owns
outright, taken back on removal, and in force from the next session rather
than the running one. Codex gets hook lines in `~/.codex/hooks.json`, merged
around whatever is already there — other tools' hooks are left alone, and so
are they on removal. Antigravity gets one named hook in
`~/.gemini/config/hooks.json`, merged around any other named hooks (its schema
is not uniform: tool events take matcher groups, the rest take flat handler
lists):

- **Backed up first.** The previous file is copied to the runtime's backup
  directory before anything is written.
- **Atomic.** Written to a temporary file and renamed, so a reader sees the old
  file or the new one, never a half-written one.
- **Idempotent.** Running Configure twice changes nothing.
- **Reversible.** Remove Integration deletes only the lines the runtime wrote.
  Hook lines belonging to other tools — and there are usually several — are
  left alone, and the appended switch is removed byte for byte. An extension
  file is deleted whole, and only while it still carries the marker line the
  record says was written into it: replace that line, or write your own file
  under that name, and nothing is touched. A copy is taken first either way, so
  even a file you had added to comes back.
- **Concurrency-aware.** The file's owner writes it too. If it changes between
  read and write, the edit is abandoned rather than clobbering it. An extension
  file has no second writer to race with: it is checked for the runtime's own
  marker, written atomically and read back.

It never touches model settings, credentials, or prompts.

---

## How agent state is read

An agent's state is a small state machine driven by hook events. The mapping is
the part most implementations get wrong, so it is spelled out here.

| Agent says | Pet shows | Why |
|---|---|---|
| `PermissionRequest` | **waiting** | The only event meaning *the agent cannot proceed without you* |
| `PreToolUse` / `PostToolUse` / `UserPromptSubmit` | running | Work in progress |
| `Stop` | celebrating, then idle | Fires at the end of *every turn*, not the session |
| `TaskCompleted` | celebrating | An actual task finished |
| `StopFailure` | failed | A failed turn is not a successful one |
| `SessionStart` | *(nothing yet)* | A process started, and not necessarily one you started — the session appears with its first real event |
| `SessionEnd` | *(removed)* | Session over |

Four details that only show up against a real agent:

**`SessionStart` is not evidence of a session you can see.** Claude Code's
background daemon pre-warms sessions: a process mints a session id, fires this
hook, and then waits to be claimed — no terminal, no transcript, and no later
event to correct the row it would have drawn. So a session that has only
announced itself is not shown; it appears at its first prompt or tool call. A
session that really is doing something reports itself a moment later, and a row
nothing can ever fill is the one kind of row that never goes away on its own.

**`Notification` is a grab bag.** It carries `permission_prompt`, `idle_prompt`,
`auth_success`, and `elicitation_dialog`, distinguished only by a field. Treating
all of it as "waiting for input" leaves the pet permanently asking for attention
as soon as you have more than one session open. Only `permission_prompt` maps;
the rest change nothing.

**`Stop` lies when a subagent is running.** It fires whenever the main agent
yields, which happens while a background subagent is still working. The payload
lists `background_tasks`; if one is still running, the turn has not finished.

**Grok reads Claude Code's config, so the runtime turns that scan off.**
Grok Build scans and trusts `~/.claude/settings.json`, which would fire the
Claude hooks on every Grok event as a second source for the same facts.
Configuring Grok appends `[compat.claude] hooks = false` to
`~/.grok/config.toml` and installs Grok's own hooks file instead. The shim
still checks `GROK_HOOK_NAME` and would re-label anything the scan delivered
anyway.

### Oh My Pi's mapping

Oh My Pi has no hook table, so the table above is Claude Code's. The extension
the runtime installs listens for eight events — and sends a ninth, the context
reading it takes at each settle — and they map like this:

| Extension says | Pet shows | Why |
|---|---|---|
| `tool_approval_requested` | **waiting** | A tool is held until you approve it — the counterpart of a permission prompt |
| `tool_execution_start` carrying `ask` | **waiting** | The `ask` tool *is* a question put to you; nothing proceeds until it is answered |
| `agent_start`, any other tool call | running | Work in progress |
| `tool_execution_end`, `tool_approval_resolved` | running | Also what takes the pet off *Needs input* once you have answered |
| `agent_end` | celebrating, then idle | Fires once per prompt — and not when the payload says `willContinue`, which means a retry is already scheduled |
| `session_start` | *(nothing yet)* | Same reasoning as Claude Code's: a process started, so the session appears at its first real event |
| `session_shutdown` | *(removed)* | Session over |
| `context_update` (sent at each settle, not an event of its own) | *(described, not moved)* | Model, context usage — the same reduced shape the status-line taps deliver |

Deliberately unmapped: `turn_start`/`turn_end` — Oh My Pi's turn is one model
call, not one prompt, so a turn boundary is not a finished piece of work — and
the message events, which carry model output and are not read at all.

Two properties of that extension are worth knowing, and both are stated in the
file itself:

**It reports and never gates.** It registers no handler that can block a tool,
rewrite an argument, or answer an approval, and every step is wrapped so a
failure cannot reach the agent. The one thing it does change is documented: Oh
My Pi skips its experimental speculative local reads
(`tools.speculativeExecution.enabled`, off by default) while any extension
handles one of the four *tool-lifecycle* events — `tool_call`, `tool_result`,
the two approval events — and this file takes the approval pair, which is what
shows an approval as **Needs input**. Removing the file restores them.

**Its payload travels in the environment, not down a pipe.** The extension runs
inside the agent's own runtime, where a write to a pipe waits its turn on an
event loop the agent may be holding. Measured on this machine: 30ms of a busy
loop between spawning the shim and writing to it was enough for the shim's
stdin deadline to expire, and the event then arrived with no session id at all —
a row the pet could never fill. The environment is handed to a process by the
kernel at spawn time, so there is nothing to be late for. (`AGENTPET_PAYLOAD_BASE64`
in `Sources/agentpet-hook/main.swift`, and the test that covers it.)

---

## How the pet animates

The published pet contract defines nine standard animation rows plus sixteen
gaze poses, each with **per-frame timings in milliseconds**. They are not
uniform: `idle` runs `280, 110, 110, 140, 140, 320` — a breath, with the ends
held two to three times as long as the middle. A single frame rate cannot
reproduce any of it, so the runtime stores a duration per frame.

Working and waiting loop their rows for as long as the state lasts — a pet
that stopped moving three seconds into a ten-minute turn would read as asleep.
A finished turn or a failure is a moment rather than a condition: its row
plays three times (Codex's own shape) and then the pet settles into the breath,
which is what stops it holding a pose. When the system asks for reduced motion,
every animation holds its first frame — the gaze is exempt, because a look pose
is already a single frame and holding "still" must not mean looking the wrong
way.

Playback is layered, first match wins:

| Layer | Driven by |
|---|---|
| 1. Dragging | which way you are moving it — `running-left` / `running-right` |
| 2. A playing gesture | one-shots: `jumping`, `waving` |
| 3. Your pointer, on the pet | `jumping` — Codex's hover: three passes, then it settles back into breathing |
| 4. Agent state | the table above |
| 5. Idle | the fallback |

Dragging outranks everything: you are holding it, and so does the pointer
landing on the pet.

Gaze is folded into the rows rather than layered under them, which is how
Codex's own sprite works: the look frame *replaces* the animation for the rows
its state offers one to. Codex offers it to `idle`, `running` and `waving`; this
runtime offers it to `idle` alone, because a look pose is a single *static*
frame and everything it replaced lost its content for as long as the pointer
was on screen. `running` made a working pet pixel-identical to a resting one;
`waving` drew the pet's hello as a stare. A waiting pet keeps asking, a working
one keeps running, the pet waves when it greets you, and the deadzone is a
single point: an idle pet looks at your cursor wherever it is, and only stops
when it is exactly on its centre.

## What the pet says

Beside the animation, the pet carries the message element Codex's own pet has:
a short status above the sprite, taken from the same vocabulary — **Running**
**Needs input** when an approval is waiting (with the tool it is for), **Ready**
when a turn finishes, **Blocked** when one fails — and the window grows upward
to fit it, so the pet itself never moves.

The row is a session: one line per open session, sessions of the same agent
kept together, the one the pet is showing first. Each row can carry the agent's
name, the last six characters of the session id, the session's name or project,
the model (with its reasoning effort), the tool it is currently using, how full
its context window is, the session's estimated cost, how much of the 5-hour and
7-day usage windows is gone, and the status message above. Every item can be
toggled and reordered in the manager's Settings; the panel can be set to stay
up or to appear only while something is happening; its width is a percentage of
the pet's own width (100–300%, slider, number field, and stepper) so it can be
up to three times the pet, and a *maximum*: the panel fits itself to its
content by default — every row on one shared set of columns, so items line up
down the panel — never wider than the maximum and never narrower than the pet.
The panel's text size is yours to set (8–20pt at the default pet — every label,
glyph and bar in the row draws at that size, and the panel widens with it, so
the setting zooms the whole panel rather than enlarging one line inside the
same box), or you can let the pet's size govern both with "Scale the panel with
the pet", which greys the two sliders out. The alignment picker says where the
panel is anchored to the pet — left, centred, or right edge — while the text
inside is always left-aligned. The pet itself never moves: the panel grows
upward and to whichever side the anchor says, and the width only ever grows at
once and shrinks after the content has stayed small. The second line of the status message is what the event
knows: which tool an approval is waiting on, what failed, and — when a turn
finishes — a preview of the assistant's last message, which Claude Code hands
to hooks as `last_assistant_message` and Codex shows the same way. It is tidied
like Codex's (whitespace collapsed, cut to 200 characters), it stays in memory,
and it never reaches a log file. Nothing you typed is ever shown.

**Model, context, cost, and rate limits** are what hooks do not carry — Claude
Code reports them only to its status line. Settings offers to tap that: the
runtime receives the status-line JSON, keeps the reduced few fields, and runs
the status line you already had through it untouched. It is off until you turn
it on, it takes effect immediately, one button puts your command back, it costs
about 2 ms per render, and it never reads a transcript. If the app is ever
deleted while the tap is on, the wrapper notices the shim is gone and hands the
status line back to your own command.

Grok reports the same numbers to its status line, so it gets its own switch in
Settings: one `[ui.status_line]` section added to `~/.grok/config.toml` whose
command feeds the runtime and prints nothing — the row stays hidden, so nothing
about your terminal changes. It is a separate toggle, off until you turn it on,
and removing it takes the section back out byte for byte. Antigravity reports
them to a status row that is visible by default, so its switch replaces the
built-in row with a plain `dir │ model │ N% ctx` one that feeds the runtime —
the terminal keeps a status line, just a simpler one.

---

## Where pets come from

Pets belong to Codex. The runtime reads Codex's own pets directory —
`$CODEX_HOME/pets`, or `~/.codex/pets` — and never writes to it:

```sh
npx codex-pets add <pet-id>     # install from codex-pets.net; run again to update
rm -rf ~/.codex/pets/<pet-id>   # remove: a pet is a folder, deleting it is the whole operation
```

Any folder in there with a `pet.json` and a spritesheet works, however it got
there — the hatch-pet skill, a download you unzipped by hand, a friend's
package. Codex's older `~/.codex/avatars/` directory is read too, for pets
packaged with an `avatar.json`, and a manifest may leave out its id or
spritesheet path exactly as Codex's loader allows. The Pet Manager lists
exactly those directories, previews each pet, and puts the one you choose on
your desktop; it does not install, import, or delete anything itself, so the
app and your terminal Codex can never disagree about what is installed. Your
choice is remembered across launches.

A folder that looks like a pet and cannot be played — a manifest whose version
contradicts the sheet, a field of the wrong type, a spritesheet that is not an
image — is **shown rather than dropped**: the manager lists it under "Not
listed" with the reason, `--diagnose` prints the same thing, and a launch with
no playable pet says which folders were refused instead of claiming the
directory is empty. The profile is decided by the atlas's measured size (V1
`1536x1872`, V2 `1536x2288`), never by the manifest's word alone.

---

## Performance

The shim runs on the agent's critical path, once per tool call, so this is the
number that decides whether the design is viable at all.

| | P50 | P95 | P99 | max |
|---|---|---|---|---|
| Runtime running | **4.33 ms** | 6.27 ms | 6.59 ms | 6.90 ms |
| Runtime not running | 3.81 ms | 5.62 ms | 6.51 ms | 6.53 ms |

Budget is P50 < 5 ms, P99 < 25 ms, over 500 samples. Swift with Foundation
starts in 3.72 ms against C's 2.23 ms; the 1.2 ms buys a JSON envelope that can
be debugged with `nc -U`.

**The shim always exits 0.** Claude Code treats a non-zero hook exit as
meaningful and will change agent behaviour in response — a pet that alters your
agents would be a far worse bug than a pet that misses an event.

The same rule applies to what the shim *says*, which is the subtler half:
Antigravity's `PreToolUse` hook requires its result to carry a `decision`, so an
observing hook cannot answer it at all, and the empty object the shim printed
there was read as a denial of every tool call (fixed 2026-09-17 — the event is
no longer installed). A hook whose result can gate the agent is not a hook this
runtime registers, however harmless an empty answer looked in testing.

---

## Privacy

Local only. Nothing is uploaded, and there is no cloud component.

The runtime reads session ids, working directories, and event names. It does
**not** read prompts, model output, or source code — not filtered, simply never
read. The integration records it writes to disk contain hook commands and
timestamps, and nothing else.

The Oh My Pi extension is held to the same allowlist from the other side: the
file the runtime installs sends a session id and a working directory for every
event, a tool name on the events that carry one, and there is no code in it
that touches a prompt, a tool argument, or any output.

When the app is not running — a relaunch, or the moment `brew upgrade` takes to
replace the bundle — the hook writes undelivered events to `pending-events/`
so the next launch can pick up where it left off. Those files are held to the
same allowlist as the event log (session id, directory, event and tool *names*;
never prompts, arguments, output, or source), written `0600`, capped at 200
events, and deleted as they are replayed.

`--log-events` writes a diagnostic capture, off by default. It keeps only the
fields diagnosis needs and drops `tool_input`, `tool_response`, and
`transcript_path` — an allowlist, so a field a future agent build adds cannot
leak into a log by default. Files are written `0600`.

One request leaves this machine: checking for updates reads the project's public
release feed from GitHub and compares the tag with the running version. It sends
nothing about you or the machine, it is skipped in headless runs, and it is the
whole of the network surface — nothing else here talks to anything.

---

## Development

```bash
swift build && swift test        # 571 tests
swift run AgentPet               # run it

swift run AgentPet --diagnose                      # what pets are discoverable, and why
swift run AgentPet --diagnose --export-frames /tmp/frames
swift run AgentPet --selftest                      # render every state, measure the output
```

`--selftest` exists because screenshots are not always available: without Screen
Recording permission, `screencapture` returns only wallpaper. It draws each
state through the live view and counts non-transparent pixels in the backing
store instead, and also asserts the pet is grabbable — a pet that renders
perfectly but cannot be dragged looks identical to a working one.

```
Sources/AgentPetCore/     Pure logic. No AppKit, so it is all testable headlessly.
├── Domain/               AgentState, AgentEvent, AgentActivity, Confidence
├── Activity/             ActivityEngine — priority, aging, focus hold, dwell
├── Bridge/               Envelope, framing, server, normalizer, hook setup
├── Pet/                  Manifest, compatibility profiles, validation, decoding
├── Integration/          Config transaction, configurators, detection
├── Runtime/              AnimationResolver, drag geometry
├── Settings/             AppConfig
└── Diagnostics/          Transition log, event capture, exportable bundle

Sources/AgentPetApp/      AppKit + SwiftUI: floating pet, manager window, menu bar
Sources/agentpet-hook/    The shim agents execute. Must always exit 0.
```

`docs/SPEC-REVIEW.md` is the design review this was built from — what held up,
what did not, and the evidence for each. `docs/ARCHITECTURE.md` is the
corrected specification.

---

## Status

| | |
|---|---|
| Core, pet loading, validation, activity engine | done |
| Floating pet, drag, gaze, position memory | done |
| Pet size — Codex's own 80–224 slider, defaulting to its 112 | done — set in the manager's Settings |
| The pointer landing on the pet plays the jump | done — Codex's hover, held on the last frame |
| The pet introduces itself once, waving | done — eight seconds, once per pet |
| Tuck the pet away and wake it again | done — the menu bar item, remembered across launches |
| Settings on ⌘, | done — the app menu's Settings… item, from wherever the manager is |
| Event bridge, verified against the real binary | done |
| Pet Manager: list Codex's pets, preview, pick one | done — read-only; pets are installed with Codex's own tooling |
| Agent Integrations: detect, configure, remove | Claude Code, Grok, Pi, Codex, Antigravity, and Oh My Pi |
| Activity Center, Settings, diagnostics export | done |
| Session panel: one row per session, configurable items | done |
| Context usage from the status line | done — opt-in: wraps Claude Code's, hidden row for Grok, plain replacement row for Antigravity |
| Survives restarts and upgrades mid-turn | done — undelivered events are replayed at the next launch |
| Window focusing | opens the project folder; hooks carry no terminal identity |

---

## License

MIT. See [LICENSE](LICENSE).
