import Foundation

/// The message a started meeting turns into.
///
/// Just the link, and above it whatever was in the draft. There is no wording wrapped
/// around it — no "Join my meeting" — because Chat annotates a bare `meet.google.com`
/// URL itself and renders it as a joinable chip in every client, and prose in front of
/// the link would be this app's voice in someone else's conversation. Anyone who wants
/// something said types it, which is what the draft is doing here.
nonisolated enum MeetInvitation {
    /// - Parameter comment: the draft the meeting was started from. Empty for the common
    ///   case of clicking the button with nothing typed.
    static func messageText(joinURL: URL, comment: String = "") -> String {
        let typed = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return joinURL.absoluteString }
        // Its own line, so a draft ending mid-sentence cannot run into the URL and take
        // the first characters of it with it — Chat's own link detection stops at
        // whitespace, and a link glued to a word is not a link at all.
        return "\(typed)\n\(joinURL.absoluteString)"
    }
}
