import Foundation

/// Everything this app says to Atrium PA, which is three calls.
///
/// The transport is MCP JSON-RPC over `POST /mcp`, not a bespoke REST
/// route. That was considered and rejected (DESIGN.md #9): for a single
/// personal client, a permanent HTTP endpoint on atrium-pa is added
/// attack surface to save about forty lines of Swift. **This project
/// makes no changes to atrium-pa** — if something here is awkward, the
/// fix belongs on this side of the wire.
///
/// The lane, in order:
///
/// 1. `POST /oauth/token`, `grant_type=client_credentials`, scope
///    `pa.ingest` → a bearer JWT.
/// 2. `tools/call upload_audio` → `{capture_id, upload_url,
///    upload_expires_in_seconds}`. `data_b64` is deliberately never
///    sent: the inline branch is capped at 64 KiB and is documented
///    server-side as the *fallback* for clients that cannot make an
///    outbound PUT. We can.
/// 3. `PUT` the bytes to `upload_url`. **No bearer on this request** —
///    the token in the path is the whole authenticator, and the route
///    answers every identity failure with an identical 404 so it cannot
///    be used as a membership oracle.
/// 4. `tools/call get_upload_status` until it reports `ready`.
///
/// The upload URL is one-shot and expires (30 minutes by default). A
/// retry therefore starts again at step 2 and mints a fresh one; a stale
/// URL is never re-PUT. Re-minting is cheap and safe: the server keys
/// ingest on the sha256 of the bytes, so re-uploading the same file
/// returns the capture that already exists instead of transcribing it
/// twice.
public actor MCPClient {

    public struct UploadTicket {
        public let captureID: Int
        public let uploadURL: URL
        public let expiresIn: Int
    }

    /// A voice in a finished recording that nobody has identified.
    ///
    /// `voiceCluster` is optional and its absence is load-bearing: an
    /// entry without one cannot be identified, named or dismissed
    /// through the API at all, and the only thing to do with it is send
    /// the user to the web UI.
    public struct UnknownSpeaker: Codable, Equatable {
        public let key: String
        public let voiceCluster: Int?
        public let turnCount: Int
        public let nameSpeakerURL: String?
        /// True only in the list `get_transcript(include_dismissed:)`
        /// returns. Everywhere else dismissed voices are filtered out
        /// before we see them, which is the whole point of dismissing
        /// one.
        public let isDismissed: Bool

        public init(
            key: String, voiceCluster: Int?, turnCount: Int, nameSpeakerURL: String?,
            isDismissed: Bool = false
        ) {
            self.key = key
            self.voiceCluster = voiceCluster
            self.turnCount = turnCount
            self.nameSpeakerURL = nameSpeakerURL
            self.isDismissed = isDismissed
        }

        /// Decoded leniently: `isDismissed` did not exist in the first
        /// version, and a queue file is read by builds newer than the
        /// one that wrote it. See `QueueItem.init(from:)`.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            voiceCluster = try c.decodeIfPresent(Int.self, forKey: .voiceCluster)
            turnCount = try c.decodeIfPresent(Int.self, forKey: .turnCount) ?? 0
            nameSpeakerURL = try c.decodeIfPresent(String.self, forKey: .nameSpeakerURL)
            isDismissed = try c.decodeIfPresent(Bool.self, forKey: .isDismissed) ?? false
        }

        public var isNameable: Bool { voiceCluster != nil }
    }

    public struct UploadStatus {
        /// One of `awaiting_upload`, `uploaded`, `transcribing`,
        /// `identifying`, `ready`, `failed`.
        public let status: String
        public let detail: String?
        public let transcriptID: Int?
        /// Present only when the recording is finished and somebody in
        /// it is unidentified. Its presence is the signal.
        public let unknownSpeakers: [UnknownSpeaker]

        public var isTerminal: Bool { status == "ready" || status == "failed" }
        public var isReady: Bool { status == "ready" }
        public var needsBytes: Bool { status == "awaiting_upload" }
    }

    public enum ClientError: Error, CustomStringConvertible {
        case notConfigured(String)
        case http(Int, String)
        case tool(String, String)
        case malformedResponse(String)
        /// There is no usable credential. The refresh token expired, was
        /// revoked, or there never was one — all of which are answered
        /// the same way, by signing in again.
        case loginRequired(String)

        public var description: String {
            switch self {
            case .notConfigured(let what): return "not configured: \(what)"
            case .http(let code, let body):
                return "HTTP \(code)\(body.isEmpty ? "" : " — \(body)")"
            case .tool(let code, let message): return "\(code): \(message)"
            case .malformedResponse(let what): return "unexpected response — \(what)"
            case .loginRequired(let why): return "sign in to Atrium PA — \(why)"
            }
        }

        /// Whether trying again later could plausibly work. A 4xx from
        /// the tool surface is a contract violation we will reproduce
        /// exactly on retry; a 5xx or a transport error is not.
        public var isRetryable: Bool {
            switch self {
            case .notConfigured: return true
            case .http(let code, _): return code >= 500 || code == 429 || code == 408
            case .tool(let code, _): return code == "INTERNAL_ERROR"
            case .malformedResponse: return false
            // Retrying cannot mint a credential. The queue holds the
            // item and the menu says to log in.
            case .loginRequired: return true
            }
        }
    }

    private let config: AtriumConfig
    private let secret: String
    private let session: URLSession

    /// A refresh token from a browser login, if there is one.
    ///
    /// Two ways to hold a credential, and the app supports both because
    /// they fail differently. `client_credentials` never expires and
    /// needs a secret someone pasted; a refresh token needs no pasting
    /// but does expire, and rotates every time it is used. When both are
    /// present the refresh token wins — it is the one bound to a user who
    /// actually consented.
    private var refreshToken: String?

    /// Cached bearer. Access tokens are good for hours; minting one per
    /// call would trip atrium-pa's per-client rate limit on a queue
    /// working through a backlog. Actor isolation is what serialises
    /// access — two concurrent uploads must not both decide the cache
    /// is cold and mint a token each.
    private var token: String?
    private var tokenExpiry = Date.distantPast

    public init(
        config: AtriumConfig, secret: String, refreshToken: String? = nil,
        session: URLSession = .shared
    ) {
        self.config = config
        self.secret = secret
        self.refreshToken = refreshToken
        self.session = session
    }

    /// Build a client from saved config plus the Keychain secret, or
    /// report precisely what is missing.
    public static func make(config: AtriumConfig, session: URLSession? = nil)
        -> Result<MCPClient, ClientError>
    {
        guard !config.baseURL.isEmpty else { return .failure(.notConfigured("baseURL")) }
        guard config.mcpURL != nil, config.tokenURL != nil else {
            return .failure(.notConfigured("baseURL is not a valid URL"))
        }
        guard !config.clientID.isEmpty else {
            return .failure(.notConfigured("clientID"))
        }
        guard let secret = Keychain.clientSecret(for: config.clientID) else {
            return .failure(.notConfigured("no credential — log in to Atrium PA"))
        }
        return .success(
            MCPClient(
                config: config, secret: secret,
                refreshToken: Keychain.refreshToken(for: config.clientID),
                session: session ?? .shared))
    }

    // MARK: - OAuth

    /// Mint or reuse a bearer for scope `pa.ingest`.
    ///
    /// Requested explicitly rather than left blank: an unscoped request
    /// is granted the client's whole `allowed_scopes` set, and a token
    /// on disk-adjacent storage should carry the least it can do the job
    /// with.
    /// The refresh in progress, if any. See `accessToken`.
    private var inFlightToken: Task<String, Error>?

    /// A bearer, minting one if the last has expired.
    ///
    /// **Single-flight, and the reason is severe.** Atrium PA rotates
    /// refresh tokens and detects reuse: presenting a token that has
    /// already been rotated revokes the whole chain, and the next call
    /// is `invalid_grant — refresh_token has been revoked`. An actor
    /// serialises calls but not *across an await* — two callers can both
    /// find no valid token, both refresh with the same stored one, and
    /// the second is a reuse.
    ///
    /// So the first caller publishes its task before suspending and
    /// everyone else waits on that.
    public func accessToken() async throws -> String {
        if let token, tokenExpiry > Date() { return token }
        if let inFlightToken { return try await inFlightToken.value }

        let task = Task<String, Error> { [self] in try await mintToken() }
        inFlightToken = task
        do {
            let minted = try await task.value
            inFlightToken = nil
            return minted
        } catch {
            inFlightToken = nil
            throw error
        }
    }

    private func mintToken() async throws -> String {
        guard let tokenURL = config.tokenURL else {
            throw ClientError.notConfigured("token endpoint")
        }

        if refreshToken != nil {
            return try await refreshAccessToken(at: tokenURL)
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // client_secret_basic. RFC 6749 §2.3.1 gives the Basic header
        // precedence over form fields, and it keeps the secret out of
        // the request body where a proxy is more likely to log it.
        let pair = "\(config.clientID):\(secret)"
        request.setValue(
            "Basic \(Data(pair.utf8).base64EncodedString())",
            forHTTPHeaderField: "Authorization")
        request.httpBody = Data("grant_type=client_credentials&scope=pa.ingest".utf8)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw ClientError.http(code, Self.errorText(from: data))
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let expires_in: Int?
        }
        guard let decoded = try? JSONDecoder().decode(TokenResponse.self, from: data)
        else { throw ClientError.malformedResponse("no access_token in token response") }

        // Expire early. A token that dies mid-upload costs a whole retry
        // cycle, and sixty seconds of slack is free.
        let lifetime = TimeInterval(decoded.expires_in ?? 3600)
        token = decoded.access_token
        tokenExpiry = Date().addingTimeInterval(max(60, lifetime - 60))
        return decoded.access_token
    }

    /// Exchange the refresh token for an access token, and store the
    /// replacement.
    ///
    /// Atrium PA rotates refresh tokens: every exchange returns a new one
    /// and burns the old. **The replacement has to be persisted before
    /// this returns**, because if the process dies holding a spent token
    /// the user is signed out with no way back but logging in again. A
    /// replayed token is worse still — the server reads it as theft and
    /// revokes the whole chain.
    private func refreshAccessToken(at tokenURL: URL) async throws -> String {
        guard let refresh = refreshToken else {
            throw ClientError.loginRequired("no refresh token")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(
            OAuthLogin.formEncoded([
                "grant_type": "refresh_token",
                "refresh_token": refresh,
                "client_id": config.clientID,
                "client_secret": secret,
            ]).utf8)

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard code == 200 else {
            // 400 invalid_grant means expired, revoked, or already
            // rotated. None of those are retryable, and all of them are
            // fixed the same way.
            if code == 400 || code == 401 {
                refreshToken = nil
                Keychain.removeRefreshToken(for: config.clientID)
                Log.write("refresh token rejected — sign-in required")
                throw ClientError.loginRequired(Self.errorText(from: data))
            }
            throw ClientError.http(code, Self.errorText(from: data))
        }

        struct Refreshed: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }
        guard let decoded = try? JSONDecoder().decode(Refreshed.self, from: data) else {
            throw ClientError.malformedResponse("no access_token when refreshing")
        }

        if let rotated = decoded.refresh_token {
            refreshToken = rotated
            try? Keychain.setRefreshToken(rotated, for: config.clientID)
        }

        let lifetime = TimeInterval(decoded.expires_in ?? 3600)
        token = decoded.access_token
        tokenExpiry = Date().addingTimeInterval(max(60, lifetime - 60))
        return decoded.access_token
    }

    // MARK: - Tools

    public func requestUpload(
        filename: String, sizeBytes: Int, title: String?, occurredAt: Date,
        language: String?
    ) async throws -> UploadTicket {
        var arguments: [String: Any] = [
            "filename": filename,
            "content_type": AudioEncoder.uploadContentType,
            "size_bytes": sizeBytes,
            "occurred_at": ISO8601DateFormatter().string(from: occurredAt),
        ]
        if let title, !title.isEmpty { arguments["title"] = title }
        if let language, !language.isEmpty { arguments["language"] = language }

        let payload = try await call(tool: "upload_audio", arguments: arguments)
        guard let captureID = payload["capture_id"] as? Int else {
            throw ClientError.malformedResponse("upload_audio returned no capture_id")
        }
        guard let urlString = payload["upload_url"] as? String,
            let url = URL(string: urlString)
        else {
            throw ClientError.malformedResponse(
                "upload_audio returned no upload_url — the inline branch was taken, "
                    + "which this client never asks for")
        }
        return UploadTicket(
            captureID: captureID,
            uploadURL: url,
            expiresIn: payload["upload_expires_in_seconds"] as? Int ?? 1800)
    }

    public func uploadStatus(captureID: Int) async throws -> UploadStatus {
        let payload = try await call(
            tool: "get_upload_status", arguments: ["capture_id": captureID])
        guard let status = payload["status"] as? String else {
            throw ClientError.malformedResponse("get_upload_status returned no status")
        }
        return UploadStatus(
            status: status,
            detail: payload["detail"] as? String,
            transcriptID: payload["transcript_id"] as? Int,
            unknownSpeakers: Self.unknownSpeakers(from: payload))
    }

    // MARK: - People

    /// Somebody Atrium PA already knows about.
    public struct Person: Equatable {
        public let id: Int
        public let displayName: String
        public let email: String?

        public init(id: Int, displayName: String, email: String?) {
            self.id = id
            self.displayName = displayName
            self.email = email
        }

        public var label: String {
            email.map { "\(displayName) — \($0)" } ?? displayName
        }
    }

    /// Find people by name, for the "somebody else" case in naming.
    ///
    /// Exists so a voice can be attached to a person who is already in
    /// Atrium PA rather than to a fresh duplicate of them. That is not a
    /// nicety: two records for the same person split their history in
    /// half, and merging them afterwards is a chore somebody has to
    /// notice is needed.
    public func searchPeople(matching query: String, limit: Int = 10) async throws
        -> [Person]
    {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Two characters is the floor the UI enforces; repeated here
        // because a one-letter search returns most of the address book
        // and is never what anyone meant.
        guard trimmed.count >= 2 else { return [] }

        let payload = try await call(
            tool: "search",
            arguments: ["query": trimmed, "types": ["person"], "limit": limit])

        // `results`, not `hits`. Measured against the live server:
        // `search` returns
        // `{"results":[{"type":"person","id":2546,"display_name":…,
        //   "primary_email":…}]}`
        // — and a parser reading the wrong key finds nothing, always,
        // with no error to say so. Which is exactly how it behaved:
        // searching for the user's own name returned an empty dropdown.
        let rows =
            payload["results"] as? [[String: Any]]
            ?? payload["hits"] as? [[String: Any]] ?? []

        var found: [Person] = []
        for hit in rows {
            guard hit["type"] as? String ?? "person" == "person",
                let id = hit["id"] as? Int
            else { continue }
            let name =
                hit["display_name"] as? String ?? hit["title"] as? String
                ?? hit["highlight"] as? String ?? "Person \(id)"
            // `primary_email`, and often null — a person known only from
            // a transcript has never had an address attached.
            let email = hit["primary_email"] as? String ?? hit["email"] as? String
            found.append(Person(id: id, displayName: name, email: email))
        }
        return found
    }

    // MARK: - Speaker identification

    /// One clip of an unnamed voice, fetchable for the next 300 s.
    public struct AudioSample: Equatable {
        public let sampleID: Int
        public let url: URL
        public let expiresIn: Int
        /// False when the server would have to slice the source to
        /// produce this, and its own retention may already have purged
        /// it. Say "this may no longer play" rather than offering a
        /// control that 404s.
        public let hasPersistedSnippet: Bool
    }

    /// A person the server thinks this voice might be.
    public struct SpeakerCandidate: Equatable {
        public let personID: Int?
        public let displayName: String
        /// 0–100, or nil when this came from the attendee list rather
        /// than from a voiceprint.
        public let matchPercent: Int?
        /// `high` / `medium` / `low`, straight from the server so the
        /// app never invents its own banding.
        public let band: String?
        /// `accepted` / `declined` / … for an attendee.
        public let rsvp: String?
        public let source: String

        /// Someone who declined the invitation was not in the room.
        public var isPlausible: Bool { rsvp?.lowercased() != "declined" }
    }

    /// What `identify_speaker` found. It gathers evidence and names
    /// nobody — deciding is the user's job, and committing is
    /// `nameSpeaker`.
    public struct SpeakerEvidence {
        public let status: String
        public let candidates: [SpeakerCandidate]
        public let spokenNames: [String]
        public let otherRecordings: Int
        public let samples: [AudioSample]
    }

    /// Gather the evidence for one unnamed voice.
    public func identifySpeaker(captureID: Int, voiceCluster: Int) async throws
        -> SpeakerEvidence
    {
        let payload = try await call(
            tool: "identify_speaker",
            arguments: ["capture_id": captureID, "voice_cluster_id": voiceCluster])

        var candidates: [SpeakerCandidate] = []
        for entry in payload["voiceprint_suggestions"] as? [[String: Any]] ?? [] {
            guard let name = entry["display_name"] as? String else { continue }
            candidates.append(
                SpeakerCandidate(
                    personID: entry["person_id"] as? Int, displayName: name,
                    matchPercent: entry["match_pct"] as? Int,
                    band: entry["match_quality"] as? String, rsvp: nil,
                    source: "voiceprint"))
        }
        for entry in payload["candidate_attendees"] as? [[String: Any]] ?? [] {
            guard let name = entry["display_name"] as? String else { continue }
            candidates.append(
                SpeakerCandidate(
                    personID: entry["person_id"] as? Int, displayName: name,
                    matchPercent: nil, band: nil, rsvp: entry["rsvp"] as? String,
                    source: "attendee"))
        }

        let spoken = (payload["spoken_evidence"] as? [[String: Any]] ?? [])
            .compactMap { $0["quote"] as? String ?? $0["name"] as? String }

        var samples: [AudioSample] = []
        for entry in payload["audio_samples"] as? [[String: Any]] ?? [] {
            guard let id = entry["sample_id"] as? Int,
                let string = entry["audio_url"] as? String,
                let url = URL(string: string)
            else { continue }
            samples.append(
                AudioSample(
                    sampleID: id, url: url,
                    expiresIn: entry["expires_in_seconds"] as? Int ?? 300,
                    hasPersistedSnippet: entry["has_persisted_snippet"] as? Bool ?? false))
        }

        let others = payload["other_recordings"] as? [[String: Any]] ?? []
        return SpeakerEvidence(
            status: payload["speaker_status"] as? String ?? "unknown",
            candidates: candidates, spokenNames: spoken,
            otherRecordings: others.count, samples: samples)
    }

    /// Fetch one snippet.
    ///
    /// No bearer: the token in the path is the whole credential, the
    /// same contract as the upload URL. The bytes are played locally and
    /// never travel anywhere else — audio in a tool result would be
    /// conversation content, and recordings of people's voices do not go
    /// to a model provider.
    public func fetchSample(_ sample: AudioSample) async throws -> Data {
        var request = URLRequest(url: sample.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200, !data.isEmpty else {
            // Expired, purged, forged and wrong-owner are deliberately
            // indistinguishable — every one answers 404 so the route
            // offers no oracle. So this cannot say which, and must not
            // pretend to.
            throw ClientError.http(code, "the clip is no longer available")
        }
        return data
    }

    public struct NamingResult {
        public let turnsUpdated: Int
        public let recordingsAffected: Int
    }

    /// Commit a name to a voice.
    ///
    /// Only ever called after an explicit press. `evidence` is stored
    /// server-side and is not decoration: it is the record of what the
    /// decision rested on, read by whoever wonders later why this voice
    /// is called this.
    public func nameSpeaker(
        captureID: Int, voiceCluster: Int, personID: Int?,
        newPerson: (name: String, email: String?)?, evidence: String
    ) async throws -> NamingResult {
        var arguments: [String: Any] = [
            "capture_id": captureID,
            "voice_cluster_id": voiceCluster,
            "evidence": ["summary": evidence],
        ]
        if let personID {
            arguments["person_id"] = personID
        } else if let newPerson {
            var create: [String: Any] = ["display_name": newPerson.name]
            if let email = newPerson.email, !email.isEmpty { create["email"] = email }
            arguments["create_person"] = create
        }

        let payload = try await call(tool: "name_speaker", arguments: arguments)
        return NamingResult(
            turnsUpdated: payload["turns_updated"] as? Int ?? 0,
            recordingsAffected: payload["recordings_affected"] as? Int ?? 0)
    }

    /// Take a name back off a voice.
    ///
    /// The server refuses to overwrite a name in place — correcting one
    /// is `unname_speaker` then `name_speaker`, deliberately two
    /// explicit decisions rather than one silent edit. Anchoring a voice
    /// to the wrong person propagates backwards through every recording
    /// it appears in, so undoing it should feel like undoing something.
    /// Note the argument list: a voice cluster and nothing else.
    ///
    /// Unlike `identify_speaker` and `name_speaker`, this one is not
    /// addressed by capture. A name belongs to the *voice*, not to the
    /// recording it was noticed in — which is the same reason naming
    /// reaches backwards through every recording that voice appears in.
    /// Sending `capture_id` is rejected outright.
    public func unnameSpeaker(voiceCluster: Int) async throws {
        _ = try await call(
            tool: "unname_speaker", arguments: ["voice_cluster_id": voiceCluster])
    }

    /// Stop being asked about a voice, without naming it — or start
    /// again, with `dismissed: false`.
    ///
    /// `dismissed` is required rather than implied, because the tool is
    /// a setter and not a verb: there is an undo, and a call that could
    /// only ever mean "yes" would have needed a second tool to undo it.
    /// Addressed by cluster alone, like `unnameSpeaker`.
    public func dismissSpeaker(voiceCluster: Int, dismissed: Bool = true) async throws {
        _ = try await call(
            tool: "dismiss_speaker",
            arguments: ["voice_cluster_id": voiceCluster, "dismissed": dismissed])
    }

    /// A voice Atrium PA has already put a name to, but only as a
    /// guess.
    ///
    /// These do **not** appear in `unknown_speakers[]` — the server
    /// considers them answered — so an app reading only that list shows
    /// nothing to do while the web UI is asking for a confirmation. A
    /// 66% "low" match against a real person is a claim about who said
    /// what, applied to every turn, on the strength of a coin flip and a
    /// bit.
    public struct ProvisionalMatch: Codable, Equatable {
        public let key: String
        public let voiceCluster: Int
        public let personID: Int
        public let displayName: String
        public let matchPercent: Int?
        /// The server's own word for the number — `low` or `medium`.
        /// Shown next to it, never replaced by our own judgement.
        public let band: String?
        public let turnCount: Int

        public init(
            key: String, voiceCluster: Int, personID: Int, displayName: String,
            matchPercent: Int?, band: String?, turnCount: Int
        ) {
            self.key = key
            self.voiceCluster = voiceCluster
            self.personID = personID
            self.displayName = displayName
            self.matchPercent = matchPercent
            self.band = band
            self.turnCount = turnCount
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            voiceCluster = try c.decode(Int.self, forKey: .voiceCluster)
            personID = try c.decode(Int.self, forKey: .personID)
            displayName = try c.decode(String.self, forKey: .displayName)
            matchPercent = try c.decodeIfPresent(Int.self, forKey: .matchPercent)
            band = try c.decodeIfPresent(String.self, forKey: .band)
            turnCount = try c.decodeIfPresent(Int.self, forKey: .turnCount) ?? 0
        }
    }

    /// A voice in a finished transcript, as the *server* has it.
    ///
    /// The roster, not a local memory of what this app asked for. Those
    /// two drifted: the queue recorded "Dana Ellis" for capture
    /// 12359 while Atrium PA had Alex Rivera, and the window showed the
    /// local copy because nothing ever compared them.
    public struct TranscriptSpeaker: Codable, Equatable {
        public let key: String
        public let voiceCluster: Int?
        public let personID: Int?
        public let displayName: String
        public let matchPercent: Int?
        public let band: String?
        /// True once somebody committed to this name. An anchored match
        /// is settled; an un-anchored one is still a guess however high
        /// its percentage.
        public let anchored: Bool
        public let turnCount: Int

        public init(
            key: String, voiceCluster: Int?, personID: Int?, displayName: String,
            matchPercent: Int?, band: String?, anchored: Bool, turnCount: Int
        ) {
            self.key = key
            self.voiceCluster = voiceCluster
            self.personID = personID
            self.displayName = displayName
            self.matchPercent = matchPercent
            self.band = band
            self.anchored = anchored
            self.turnCount = turnCount
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            key = try c.decode(String.self, forKey: .key)
            voiceCluster = try c.decodeIfPresent(Int.self, forKey: .voiceCluster)
            personID = try c.decodeIfPresent(Int.self, forKey: .personID)
            displayName = try c.decode(String.self, forKey: .displayName)
            matchPercent = try c.decodeIfPresent(Int.self, forKey: .matchPercent)
            band = try c.decodeIfPresent(String.self, forKey: .band)
            anchored = try c.decodeIfPresent(Bool.self, forKey: .anchored) ?? false
            turnCount = try c.decodeIfPresent(Int.self, forKey: .turnCount) ?? 0
        }

        /// A name applied on a guess nobody has agreed to.
        public var isProvisional: Bool {
            !anchored && (band == "low" || band == "medium") && personID != nil
        }
    }

    /// What the server knows about a recording: its title and its cast.
    ///
    /// Both come out of one `get_transcript`, which is why they are
    /// fetched together rather than by two calls that would say the
    /// same thing twice.
    public struct TranscriptDetails: Equatable {
        /// The server's own title, derived from the transcript.
        ///
        /// This app deliberately sends none — a label naming the app
        /// that did the capturing answers a different question than the
        /// field asks. Reading this back is the other half of that
        /// decision: without it the recordings list shows the local
        /// source label for ever and never learns what the meeting was
        /// actually about.
        public let title: String?
        public let speakers: [TranscriptSpeaker]
    }

    public func transcriptDetails(transcriptID: Int) async throws -> TranscriptDetails {
        let payload = try await call(
            tool: "get_transcript",
            arguments: ["transcript_id": transcriptID, "summary_max_chars": 0])

        let title = (payload["title"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptDetails(
            title: (title?.isEmpty ?? true) ? nil : title,
            speakers: Self.roster(from: payload))
    }

    /// Who the server says was in this recording.
    public func speakers(transcriptID: Int) async throws -> [TranscriptSpeaker] {
        try await transcriptDetails(transcriptID: transcriptID).speakers
    }

    private static func roster(from payload: [String: Any]) -> [TranscriptSpeaker] {
        (payload["speakers"] as? [[String: Any]] ?? []).map { row in
            TranscriptSpeaker(
                key: row["key"] as? String ?? "Speaker",
                voiceCluster: row["voice_cluster_id"] as? Int,
                personID: row["person_id"] as? Int,
                displayName: row["display_name"] as? String ?? "Unnamed",
                matchPercent: row["match_pct"] as? Int,
                band: row["match_quality"] as? String,
                anchored: row["anchored"] as? Bool ?? false,
                turnCount: row["turn_count"] as? Int ?? 0)
        }
    }

    /// Names applied as a guess, awaiting a yes or a no.
    ///
    /// `anchored` is the distinction that matters: an anchored name is
    /// one somebody committed to, and re-asking about it would be
    /// nagging. A `high` match is anchored by the server and carries no
    /// verify link by design, so it is not offered here either.
    public func provisionalSpeakers(transcriptID: Int) async throws
        -> [ProvisionalMatch]
    {
        try await speakers(transcriptID: transcriptID)
            .filter(\.isProvisional)
            .compactMap { speaker in
                guard let cluster = speaker.voiceCluster, let person = speaker.personID
                else { return nil }
                return ProvisionalMatch(
                    key: speaker.key, voiceCluster: cluster, personID: person,
                    displayName: speaker.displayName,
                    matchPercent: speaker.matchPercent, band: speaker.band,
                    turnCount: speaker.turnCount)
            }
    }

    /// Where to fetch a whole transcript, and for how long.
    public struct TranscriptExport: Equatable {
        public let url: URL
        public let expiresIn: Int
        public let sizeBytes: Int
        /// A quarantined transcript exports metadata only — no turns and
        /// no speakers. Worth saying rather than writing an empty file.
        public let quarantined: Bool
    }

    /// Ask for a link to the whole transcript.
    ///
    /// The document does not come back through the tool call — a
    /// three-hour meeting is a megabyte or two — so this returns a URL
    /// good for 300 seconds. Fetch it with `fetchExport`.
    public func transcriptExport(transcriptID: Int) async throws -> TranscriptExport {
        let payload = try await call(
            tool: "get_transcript_download",
            arguments: ["transcript_id": transcriptID])

        guard let raw = payload["download_url"] as? String, let url = URL(string: raw)
        else {
            throw ClientError.malformedResponse("no download_url in the response")
        }
        return TranscriptExport(
            url: url,
            expiresIn: payload["download_expires_in_seconds"] as? Int ?? 300,
            sizeBytes: payload["size_bytes"] as? Int ?? 0,
            quarantined: payload["quarantined"] as? Bool ?? false)
    }

    /// Fetch the exported document.
    ///
    /// **No Authorization header.** The token is in the path, exactly as
    /// it is for an upload URL — sending a bearer as well would be
    /// harmless but would misrepresent how this is authorised to anyone
    /// reading a packet capture.
    public func fetchExport(_ export: TranscriptExport) async throws -> Data {
        var request = URLRequest(url: export.url)
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            // 404 here is most likely the 300-second window having
            // closed. Ask again rather than retrying a dead link.
            throw ClientError.http(code, Self.errorText(from: data))
        }
        return data
    }

    /// One client per deployment, shared.
    ///
    /// Four places used to build their own — the queue, the launch
    /// check, naming, deleting — each with its own in-memory bearer and
    /// all reading the same refresh token out of the keychain. With
    /// rotation and reuse detection on the server that is not a
    /// duplicated request, it is a revoked account: two of them
    /// refreshing at once means the second presents a token the first
    /// has already rotated. Measured, at a launch where the roster
    /// backfill and the login check overlapped:
    /// `invalid_grant — refresh_token has been revoked`.
    ///
    /// Sharing one instance also means one in-memory token, so most of
    /// those refreshes stop happening at all.
    private nonisolated(unsafe) static var pool: [String: MCPClient] = [:]
    private nonisolated(unsafe) static let poolLock = NSLock()

    public static func shared(config: AtriumConfig) -> Result<MCPClient, ClientError> {
        guard config.isConfigured else {
            return .failure(.notConfigured("base URL or client id"))
        }
        let key = "\(config.baseURL)|\(config.clientID)"
        poolLock.lock()
        defer { poolLock.unlock() }
        if let existing = pool[key] { return .success(existing) }

        switch make(config: config) {
        case .success(let made):
            pool[key] = made
            return .success(made)
        case .failure(let error):
            return .failure(error)
        }
    }

    /// Drop the shared clients. Called when the credentials change —
    /// signing in, signing out, or pointing at a different server —
    /// because a cached client holds a bearer for the old identity.
    public static func forgetShared() {
        poolLock.lock()
        defer { poolLock.unlock() }
        pool.removeAll()
    }

    /// Voices in this transcript that were dismissed.
    ///
    /// Dismissing a voice hides it from `unknown_speakers[]` everywhere
    /// else, which is what makes it stop being asked about — and also
    /// what makes it unreachable, because `dismiss_speaker(dismissed:
    /// false)` needs the cluster id that has just been hidden.
    /// `get_transcript(include_dismissed: true)` is the way back in;
    /// atrium-pa calls the alternative "a one-way door".
    ///
    /// Needs `pa.read`, which is why the login scope includes it.
    public func dismissedSpeakers(transcriptID: Int) async throws -> [UnknownSpeaker] {
        let payload = try await call(
            tool: "get_transcript",
            arguments: [
                "transcript_id": transcriptID,
                "include_dismissed": true,
                // The summary is the expensive part of this response and
                // nothing here reads it.
                "summary_max_chars": 0,
            ])
        return Self.unknownSpeakers(from: payload).filter(\.isDismissed)
    }

    /// Start being asked about a voice again. Nothing was deleted when
    /// it was dismissed — the turns, the samples and the voice print are
    /// untouched — so this restores the question, not the data.
    public func restoreSpeaker(voiceCluster: Int) async throws {
        try await dismissSpeaker(voiceCluster: voiceCluster, dismissed: false)
    }

    /// What `delete_capture` reports back.
    public struct DeletionResult: Equatable {
        public let captureID: Int
        public let status: String
        public let deleted: Bool
        /// The state the call *found*, before doing anything.
        public let alreadyDeleted: Bool
        /// Whether this call moved anything. False on a retry that
        /// arrived after the first one had already landed.
        public let changed: Bool
    }

    /// Soft-delete a capture, or restore one.
    ///
    /// Reaches only recordings uploaded through `upload_audio`; anything
    /// else in the operator's vault answers `NOT_FOUND`, which is the
    /// same non-disclosure a wrong owner gets.
    ///
    /// **This does not delete the audio.** The blobs in Atrium PA's
    /// vault are unlinked by a separate job on file age, independent of
    /// whether anything was deleted — so a deleted capture's audio sits
    /// there until its own TTL expires. Saying "deleted" and meaning
    /// "gone" is the mistake this comment exists to prevent.
    ///
    /// `deleted` is required and has no default, like
    /// `dismissSpeaker`: the tool is a setter, and a call that could
    /// only ever mean "yes" would have needed a second tool to undo it.
    /// Undo matters more here than usual — see `atrium-mac`'s delete
    /// dialog for why re-uploading the same file is not a way back.
    @discardableResult
    public func deleteCapture(
        captureID: Int, deleted: Bool = true, reason: String? = nil
    ) async throws -> DeletionResult {
        var arguments: [String: Any] = [
            "capture_id": captureID, "deleted": deleted,
        ]
        if let reason, !reason.isEmpty { arguments["reason"] = reason }
        let payload = try await call(tool: "delete_capture", arguments: arguments)

        return DeletionResult(
            captureID: payload["capture_id"] as? Int ?? captureID,
            status: payload["status"] as? String ?? "unknown",
            deleted: payload["deleted"] as? Bool ?? deleted,
            alreadyDeleted: payload["already_deleted"] as? Bool ?? false,
            changed: payload["changed"] as? Bool ?? false)
    }

    /// PUT the bytes. Streamed from the file — a 45 MB meeting has no
    /// business being resident in memory, and the server accepts up to
    /// 300 MiB.
    public func putAudio(fileURL: URL, to uploadURL: URL) async throws {
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.setValue(
            AudioEncoder.uploadContentType, forHTTPHeaderField: "Content-Type")
        // Deliberately no Authorization header: the token is in the
        // path. Sending a bearer here would be harmless but misleading
        // to anyone reading a packet capture.
        request.timeoutInterval = 600

        let (data, response) = try await session.upload(for: request, fromFile: fileURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            // 404 here is the route's uniform answer to every identity
            // or existence failure — expired token, already consumed,
            // wrong owner. It is not distinguishable by design, so the
            // only correct response is to re-mint and try again.
            throw ClientError.http(code, Self.errorText(from: data))
        }
    }

    // MARK: - JSON-RPC

    private func call(tool: String, arguments: [String: Any]) async throws
        -> [String: Any]
    {
        guard let mcpURL = config.mcpURL else {
            throw ClientError.notConfigured("mcp endpoint")
        }
        let bearer = try await accessToken()

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            // The server is stateless per request — there is no
            // `initialize` handshake to keep alive — so a fixed id is
            // honest rather than lazy.
            "id": 1,
            "method": "tools/call",
            "params": ["name": tool, "arguments": arguments],
        ]

        var request = URLRequest(url: mcpURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Not `text/event-stream`: the server picks its response shape
        // from Accept, and a single tool call has nothing to stream.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard let envelope = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw ClientError.http(code, Self.errorText(from: data))
        }

        // Transport-level failures (auth, forbidden scope) arrive as an
        // HTTP status with an MCP error envelope rather than a JSON-RPC
        // error member.
        if code != 200 {
            if let error = envelope["error"] as? [String: Any] {
                throw Self.failure(
                    code: error["code"] as? String ?? "HTTP_\(code)",
                    message: error["message"] as? String ?? "")
            }
            throw ClientError.http(code, Self.errorText(from: data))
        }

        if let error = envelope["error"] as? [String: Any] {
            throw Self.failure(
                code: String(describing: error["code"] ?? "JSONRPC_ERROR"),
                message: error["message"] as? String ?? "")
        }

        guard let result = envelope["result"] as? [String: Any] else {
            throw ClientError.malformedResponse("no result member")
        }

        // Tool-level failures come back as a successful JSON-RPC result
        // carrying `isError: true`, per the MCP streamable-HTTP spec.
        if result["isError"] as? Bool == true {
            let structured = result["structuredContent"] as? [String: Any]
            let error = structured?["error"] as? [String: Any]
            let code = error?["code"] as? String ?? "TOOL_ERROR"
            let message = error?["message"] as? String ?? Self.textContent(of: result)
            throw Self.failure(code: code, message: message)
        }

        if let structured = result["structuredContent"] as? [String: Any] {
            return structured
        }
        // Fall back to parsing the text content block. Not expected —
        // this server always sends structuredContent — but a client that
        // hard-fails on its absence would break on a spec-compliant
        // server that does not.
        let text = Self.textContent(of: result)
        guard let data = text.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw ClientError.malformedResponse("result had no structuredContent") }
        return parsed
    }

    private static func unknownSpeakers(from payload: [String: Any]) -> [UnknownSpeaker] {
        guard let raw = payload["unknown_speakers"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let key = entry["key"] as? String else { return nil }
            return UnknownSpeaker(
                key: key,
                voiceCluster: entry["voice_cluster_id"] as? Int,
                turnCount: entry["turn_count"] as? Int ?? 0,
                nameSpeakerURL: entry["name_speaker_url"] as? String,
                isDismissed: entry["dismissed"] as? Bool ?? false)
        }
    }

    // MARK: - Helpers

    /// Turn a server error code into the right kind of failure.
    ///
    /// `FORBIDDEN` is always a scope problem, and a token cannot grow a
    /// scope it was not issued with — the only fix is to sign in again.
    /// Saying so is the whole point: this arrives on three different
    /// paths (an HTTP status, a JSON-RPC error member, and a tool result
    /// with `isError`), and it used to be recognised on only one of
    /// them. Measured: a `get_transcript` call on a token minted before
    /// this app asked for `pa.read` reported the raw
    /// `FORBIDDEN: tool 'get_transcript' requires scope 'pa.read'`,
    /// which reads like a bug in the app rather than an instruction.
    ///
    /// The server's own message names the scope, so it is passed through
    /// rather than guessed at.
    private static func failure(code: String, message: String) -> ClientError {
        if code == "FORBIDDEN" || code == "UNAUTHORIZED" {
            return .loginRequired(message)
        }
        return .tool(code, message)
    }

    private static func textContent(of result: [String: Any]) -> String {
        guard let content = result["content"] as? [[String: Any]] else { return "" }
        return content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    }

    /// A short, safe rendering of an error body for a log line or a menu
    /// entry. Truncated because some failures return an HTML page.
    private static func errorText(from data: Data) -> String {
        guard let text = String(data: data, encoding: .utf8) else { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > 300 ? String(trimmed.prefix(300)) + "…" : trimmed
    }
}
