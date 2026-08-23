import CryptoKit
import Foundation

/// Browser login: "Log in to Atrium PA" instead of "paste a client ID
/// and secret".
///
/// The whole flow, none of which the user sees except step 3:
///
/// 1. **Bind a loopback listener** on 127.0.0.1 and learn its port. This
///    happens first because the port has to appear in the redirect URI
///    that step 2 registers.
/// 2. **Register a client** (RFC 7591 dynamic client registration,
///    `POST /oauth/register`) asking for `pa.ingest`. Atrium PA hands
///    back a `client_id` and `client_secret`, so nobody has to mint one
///    in an admin UI or paste anything.
/// 3. **Open the browser** at `/oauth/authorize` with PKCE. The user
///    signs in to Atrium PA normally and clicks Allow.
/// 4. **Catch the redirect** on the loopback listener and read the code.
/// 5. **Exchange** code + verifier for an access token and a refresh
///    token, and keep the refresh token.
///
/// ## Why this works here and would not have a week ago
///
/// Three things on the server side make it viable, and all three are
/// worth naming because if any changes this stops working:
///
/// * `pa.ingest` is in atrium-pa's `DEFAULT_SCOPES`, which is the gate
///   dynamic registration validates against. A self-registered client
///   can therefore be granted it.
/// * `oauth_dcr_enabled` defaults to true.
/// * `127.0.0.1` and `localhost` are in the default
///   `oauth_redirect_allowed_hosts`, and plain HTTP is permitted for
///   loopback hosts specifically.
///
/// **No changes to atrium-pa are required, and none were made.**
///
/// ## What is stored, and where
///
/// The registered client's ID goes in `config.json`; its secret and the
/// refresh token go in the login keychain. Access tokens are never
/// persisted — they live for an hour and are cheap to re-mint from the
/// refresh token.
///
/// Refresh tokens rotate on every use and carry a 14-day ceiling that
/// each use extends. An app that uploads a meeting now and then stays
/// signed in indefinitely; one left idle for a fortnight has to be
/// logged in again, which `MCPClient` reports as
/// `ClientError.loginRequired` rather than as a mysterious 401.
public enum OAuthLogin {

    public struct Result {
        public let clientID: String
        public let clientSecret: String
        public let refreshToken: String
        public let accessToken: String
        public let scope: String
    }

    public enum LoginError: Error, CustomStringConvertible {
        case notConfigured
        case listenerFailed(String)
        case registrationFailed(String)
        case cancelled
        case timedOut
        case denied(String)
        /// The client exists but may not be granted what was asked for.
        /// Distinct from `denied` because it is fixable without the user
        /// doing anything: register a new client and ask again.
        case scopeRejected(String)
        case stateMismatch
        case exchangeFailed(String)

        public var description: String {
            switch self {
            case .notConfigured: return "no Atrium PA base URL configured"
            case .listenerFailed(let why):
                return "could not open a local callback listener — \(why)"
            case .registrationFailed(let why):
                return "Atrium PA refused to register this app — \(why)"
            case .cancelled: return "login was cancelled"
            case .timedOut: return "login was not completed in time"
            case .denied(let why): return "access was not granted — \(why)"
            case .scopeRejected(let why):
                return "this Atrium PA client may not be granted \(scope) — \(why)"
            case .stateMismatch:
                return "the browser came back with the wrong state — login abandoned"
            case .exchangeFailed(let why): return "could not exchange the code — \(why)"
            }
        }
    }

    /// Scopes asked for, and no more.
    ///
    /// `pa.ingest` uploads recordings. `pa.label` is what
    /// `identify_speaker` and `name_speaker` require, so the app can put
    /// a name to a voice without sending the user to a browser.
    ///
    /// `pa.read` is the widest of the three and was deliberately absent
    /// until the naming window grew a *search for an existing person*
    /// box. There is no narrower way to do that: `search`, `resolve` and
    /// every entity reader on the server require `pa.read`, and the
    /// alternative is a name field that can only ever create duplicates
    /// of people Atrium PA already knows.
    ///
    /// It should be understood for what it is. `pa.read` is read access
    /// to the whole personal-assistant surface — mail, calendar,
    /// transcripts, people — not just the roster. This token sits in the
    /// login keychain of the machine doing the recording, so the blast
    /// radius of losing that machine grew when this line changed.
    ///
    /// Still no `pa.admin`: nothing here manages OAuth clients.
    ///
    /// `pa.ingest:delete` is separate from `pa.ingest` on purpose, and
    /// the reason is not this app's: folding deletion into the upload
    /// scope would have re-granted it to every token already issued,
    /// against a consent screen that cannot be shown again.
    ///
    /// It is **not** advertised in the server's discovery document, so a
    /// client that registers without naming its scopes never receives
    /// it. This one names them — see `register()`, which sends `scope`
    /// explicitly — and that is load-bearing rather than incidental.
    ///
    /// Adding a scope does not retrofit onto a token already issued — a
    /// client registered before this line changed keeps what it was
    /// granted, and re-consenting does not widen it either, because
    /// `allowed_scopes` is pinned at registration (RFC 7591 §2). The
    /// only way through is a new registration, which `run()` does when
    /// the callback comes back `invalid_scope`. `MCPClient` reports the
    /// resulting FORBIDDEN as `loginRequired` rather than as a bare 403.
    public static let scope = "pa.ingest pa.label pa.read pa.ingest:delete"

    /// How long the user has to finish signing in before the listener
    /// gives up and closes.
    public static let timeout: TimeInterval = 300

    /// Run the whole flow. `openURL` is injected so the caller supplies
    /// `NSWorkspace.shared.open` and a test can supply something that
    /// does not launch a browser.
    public static func run(
        config: AtriumConfig,
        existingClient: (id: String, secret: String)? = nil,
        session: URLSession = .shared,
        openURL: @escaping (URL) -> Void
    ) async throws -> Result {
        guard let base = config.oauthBase else { throw LoginError.notConfigured }

        let listener = try CallbackListener()
        defer { listener.stop() }
        let redirectURI = "http://127.0.0.1:\(listener.port)/callback"

        // Reuse the registered client if there is one, so signing in
        // again does not leave a trail of registrations behind.
        if let existingClient {
            do {
                return try await authorize(
                    base: base, client: existingClient, redirectURI: redirectURI,
                    listener: listener, session: session, openURL: openURL)
            } catch LoginError.scopeRejected(let why) {
                // RFC 7591 §2: the `scope` sent at registration is the
                // *maximum* the client may ever request, and atrium-pa
                // pins it into `allowed_scopes` at that moment. A client
                // registered when this app asked for `pa.ingest pa.label`
                // can therefore never be granted `pa.read` — not by
                // signing in again, and not by refreshing, since RFC 6749
                // §6 forbids widening on refresh either. The only way
                // through is a new registration.
                //
                // Worth the extra client row: the alternative is an app
                // that tells the user to sign in again and then fails the
                // same way, with no path out except editing config.json.
                Log.write(
                    "login: the existing client cannot be granted \(scope) — \(why); "
                        + "registering a new one")
            }
        }

        let client = try await register(
            base: base, redirectURI: redirectURI, session: session)
        return try await authorize(
            base: base, client: client, redirectURI: redirectURI,
            listener: listener, session: session, openURL: openURL)
    }

    /// Consent in the browser, then swap the code for tokens.
    private static func authorize(
        base: URL,
        client: (id: String, secret: String),
        redirectURI: String,
        listener: CallbackListener,
        session: URLSession,
        openURL: @escaping (URL) -> Void
    ) async throws -> Result {
        let verifier = randomURLSafe(64)
        let challenge = Self.challenge(for: verifier)
        let state = randomURLSafe(24)

        var components = URLComponents(
            url: base.appending(path: "oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scope),
        ]
        guard let authorizeURL = components.url else { throw LoginError.notConfigured }

        Log.write("login: opening the browser for consent")
        openURL(authorizeURL)

        let callback = try await listener.waitForCallback(timeout: timeout)
        if let error = callback["error"] {
            let why = callback["error_description"] ?? error
            // Delivered as a redirect to the loopback rather than as an
            // error page, per RFC 6749 §4.1.2.1 — which is the only
            // reason this app can see it and recover.
            if error == "invalid_scope" { throw LoginError.scopeRejected(why) }
            throw LoginError.denied(why)
        }
        guard callback["state"] == state else { throw LoginError.stateMismatch }
        guard let code = callback["code"] else {
            throw LoginError.denied("no authorization code came back")
        }

        let tokens = try await exchange(
            base: base, client: client, code: code, verifier: verifier,
            redirectURI: redirectURI, session: session)

        Log.write("login: succeeded, scope \(tokens.scope)")
        return Result(
            clientID: client.id, clientSecret: client.secret,
            refreshToken: tokens.refresh, accessToken: tokens.access,
            scope: tokens.scope)
    }

    // MARK: - Dynamic client registration

    private struct Registration: Decodable {
        let client_id: String
        let client_secret: String?
    }

    private static func register(
        base: URL, redirectURI: String, session: URLSession
    ) async throws -> (id: String, secret: String) {
        var request = URLRequest(url: base.appending(path: "oauth/register"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "Atrium PA Capture (Mac)",
            "redirect_uris": [redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "client_secret_post",
            "scope": scope,
        ])

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status),
            let decoded = try? JSONDecoder().decode(Registration.self, from: data),
            let secret = decoded.client_secret
        else {
            throw LoginError.registrationFailed(shortBody(data, status: status))
        }
        Log.write("login: registered a client for scope \(scope)")
        return (decoded.client_id, secret)
    }

    // MARK: - Code exchange

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let scope: String?
    }

    private static func exchange(
        base: URL, client: (id: String, secret: String), code: String,
        verifier: String, redirectURI: String, session: URLSession
    ) async throws -> (access: String, refresh: String, scope: String) {
        var request = URLRequest(url: base.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            formEncoded([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirectURI,
                "code_verifier": verifier,
                "client_id": client.id,
                "client_secret": client.secret,
            ]).utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200,
            let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data),
            let refresh = decoded.refresh_token
        else {
            throw LoginError.exchangeFailed(shortBody(data, status: status))
        }
        return (decoded.access_token, refresh, decoded.scope ?? scope)
    }

    // MARK: - Helpers

    public static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.keys.sorted().map { key in
            let value = fields[key]!.addingPercentEncoding(
                withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(value)"
        }.joined(separator: "&")
    }

    /// RFC 7636 §4.2: url-safe base64 of the SHA-256 of the verifier,
    /// unpadded. Atrium PA accepts no other method, and a challenge
    /// computed wrong fails at the very end of the flow — after the user
    /// has already signed in — so it is worth a test of its own.
    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8)))
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// RFC 7636 code verifier / opaque state. `SystemRandomNumberGenerator`
    /// is the CSPRNG; this is not a place for `Int.random(in:)` seeded
    /// off anything predictable.
    public static func randomURLSafe(_ bytes: Int) -> String {
        var raw = [UInt8](repeating: 0, count: bytes)
        var generator = SystemRandomNumberGenerator()
        for index in raw.indices { raw[index] = UInt8.random(in: 0...255, using: &generator) }
        return Data(raw).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func shortBody(_ data: Data, status: Int) -> String {
        let text = String(data: data, encoding: .utf8) ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = trimmed.count > 200 ? String(trimmed.prefix(200)) + "…" : trimmed
        return "HTTP \(status)\(clipped.isEmpty ? "" : " — \(clipped)")"
    }
}
