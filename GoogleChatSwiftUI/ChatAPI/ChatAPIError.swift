import Foundation

nonisolated struct ChatAPIError: LocalizedError, Sendable {
    let status: Int
    /// Google's canonical error status, e.g. `PERMISSION_DENIED`.
    let googleStatus: String?
    let message: String?

    var errorDescription: String? {
        if let message, let googleStatus {
            return "Chat API \(status) \(googleStatus): \(message)"
        }
        if let message { return "Chat API \(status): \(message)" }
        return "Chat API request failed with HTTP \(status)."
    }

    /// Whether a delete was refused for having threaded replies beneath it.
    ///
    /// Recoverable, but only by widening what is being deleted: the same call with
    /// `force` takes the replies too. That is a decision for the person deleting,
    /// not something to retry behind their back.
    var requiresForcedDelete: Bool { googleStatus == "FAILED_PRECONDITION" }

    /// Whether retrying the identical request could plausibly succeed.
    var isRetryable: Bool {
        status == 429 || status == 500 || status == 502 || status == 503 || status == 504
    }

    /// Google's error envelope: `{"error": {"code": …, "status": …, "message": …}}`.
    static func decode(status: Int, from data: Data) -> ChatAPIError {
        struct Envelope: Decodable {
            struct Inner: Decodable {
                let code: Int?
                let message: String?
                let status: String?
            }
            let error: Inner?
        }
        let decoded = try? JSONDecoder().decode(Envelope.self, from: data)
        return ChatAPIError(
            status: status,
            googleStatus: decoded?.error?.status,
            message: decoded?.error?.message ?? String(data: data, encoding: .utf8)
        )
    }
}
