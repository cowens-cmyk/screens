import Foundation

/// When to ask the DeckLink helper for a port's display modes. Asking walks
/// the driver in the helper that feeds the outputs, so the background look
/// (every 8 s) doesn't ask a port whose modes it already has. A port with
/// no modes known is asked again on every look: an empty answer is what a
/// failed reply or a helper that wasn't ready yet gives, and the output
/// mode is picked from this list, so it must heal by itself.
public enum DeckLinkModeAsking {

    /// The ports to ask, in the order they're present: every one when
    /// Settings asks (`allModes`, a port remapped in Desktop Video Setup
    /// shows its new modes); otherwise one not seen on the last look (it
    /// came back) and one whose modes aren't known or came back empty.
    public static func portsToAsk(
        present: [Int64], seen: Set<Int64>, modeCounts: [Int64: Int], allModes: Bool
    ) -> [Int64] {
        present.filter { port in
            allModes || !seen.contains(port) || (modeCounts[port] ?? 0) == 0
        }
    }

    /// Whether an answer replaces what's kept: a list of modes always, an
    /// empty one only when nothing better is known (an empty answer never
    /// wipes out modes a port gave before).
    public static func keeps(answerCount: Int, knownCount: Int?) -> Bool {
        answerCount > 0 || (knownCount ?? 0) == 0
    }
}
