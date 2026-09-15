import Foundation

/// The glyph an agent is shown by, wherever the app has room for a mark rather
/// than a name.
///
/// One mapping for the whole app: the pet's panel and the manager's activity
/// list draw the same agent the same way, which is the only way a glyph means
/// anything.
///
/// Apple's symbols, deliberately. An agent's logo belongs to whoever makes it,
/// and a third-party app that draws those marks takes on a trademark question
/// it does not need. These are generic glyphs — a terminal, a bolt, a function
/// sign — chosen because they read at eleven points.
enum AgentGlyph {

    static func symbol(for agentID: String) -> String {
        switch agentID {
        case "claude-code": return "asterisk"
        case "codex":       return "terminal"
        case "grok":        return "bolt"
        case "pi":          return "function"
        case "antigravity": return "sparkles"
        case "omp":         return "sum"
        default:            return "pawprint"
        }
    }
}
