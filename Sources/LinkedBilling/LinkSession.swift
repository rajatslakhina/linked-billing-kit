import Foundation

/// The iOS half of the "Link your Claude organization" flow.
///
/// Your back end pushes the authorization request (PAR) with PKCE and a `state`
/// value, then hands the app the authorize URL and that `state`. The app opens the
/// URL in `ASWebAuthenticationSession` and gets a callback URL back. This type checks
/// both ends before anything reaches your back end:
///
/// - the authorize URL is `https` on an allow-listed host (default `auth.claude.com`),
///   so a tampered response can't send the user to a look-alike sign-in page;
/// - the callback matches the registered redirect, carries the expected `state`
///   (compared in constant time), arrives within the TTL, and is used once.
///
/// The PKCE verifier and the code exchange stay on the back end: the app only ever
/// forwards the one-time `code`.
public final class LinkSession: @unchecked Sendable {
    // @unchecked: the only mutable state, `consumed`, is guarded by `lock`. A class (not a
    // struct) so "used once" can't be defeated by copying the value.
    public struct Redirect: Hashable, Sendable {
        public let scheme: String
        public let host: String?
        public let path: String

        public init(scheme: String, host: String?, path: String = "") {
            self.scheme = scheme.lowercased()
            self.host = host?.lowercased()
            self.path = path
        }
    }

    public enum StartError: Error, Hashable, Sendable {
        case insecureScheme
        case hostNotAllowed(String)
        case stateTooShort
    }

    public enum CallbackResult: Hashable, Sendable {
        /// Forward this code to your back end for the exchange.
        case code(String)
        /// The user pressed Cancel, or the authorization server returned an error.
        case denied(error: String)
        case rejected(Rejection)
    }

    public enum Rejection: Hashable, Sendable {
        case redirectMismatch
        case stateMismatch
        case expired
        case alreadyUsed
        case missingCode
    }

    public let authorizeURL: URL
    public let redirect: Redirect
    public let createdAt: EpochMillis
    public let ttlMillis: Int64
    private let state: String
    private let lock = NSLock()
    private var consumed = false

    public static let defaultAllowedHosts: Set<String> = ["auth.claude.com"]

    /// - Parameter state: the opaque value your back end put in the pushed request.
    ///   At least 22 characters (about 128 bits of base64url entropy).
    public init(authorizeURL: URL, state: String, redirect: Redirect, createdAt: EpochMillis,
                ttlMillis: Int64 = 10 * 60_000,
                allowedHosts: Set<String> = LinkSession.defaultAllowedHosts) throws {
        guard let components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https" else { throw StartError.insecureScheme }
        let host = components.host?.lowercased() ?? ""
        guard allowedHosts.contains(host) else { throw StartError.hostNotAllowed(host) }
        guard state.utf8.count >= 22 else { throw StartError.stateTooShort }
        self.authorizeURL = authorizeURL
        self.state = state
        self.redirect = redirect
        self.createdAt = createdAt
        self.ttlMillis = min(max(1_000, ttlMillis), 60 * 60_000)
    }

    /// Validate the callback.
    ///
    /// The session is consumed by any callback that carries the right `state`
    /// (a code, a denial, or a malformed answer) and by expiry. A redirect or `state`
    /// mismatch does not consume it: an unrelated or forged URL must not be able to
    /// cancel the user's real sign-in, and a 128-bit `state` can't be guessed by retrying.
    public func handleCallback(_ url: URL, at now: EpochMillis) -> CallbackResult {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == redirect.scheme,
              components.host?.lowercased() == redirect.host,
              components.path == redirect.path else { return .rejected(.redirectMismatch) }

        lock.lock(); defer { lock.unlock() }
        guard !consumed else { return .rejected(.alreadyUsed) }
        guard now >= createdAt, now <= Saturating.add(createdAt, ttlMillis) else {
            consumed = true
            return .rejected(.expired)
        }

        let items = components.queryItems ?? []
        // Exactly one `state`: duplicate parameters are a classic parser-confusion trick.
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, let received = states.first?.value,
              Self.constantTimeEquals(received, state) else { return .rejected(.stateMismatch) }
        consumed = true

        if let error = items.first(where: { $0.name == "error" })?.value {
            return .denied(error: error)
        }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty, code.utf8.count <= 2_048 else {
            return .rejected(.missingCode)
        }
        return .code(code)
    }

    /// Compares every byte regardless of where the first difference is, so response
    /// timing doesn't reveal how much of a guessed `state` was right. (Length is not
    /// secret: the format is fixed.)
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for index in x.indices { diff |= x[index] ^ y[index] } // same count: index valid in both
        return diff == 0
    }
}
