import Foundation
import AppKit
import Network
import CryptoKit
import Security

// MARK: - Keychain (first credentialed integration — this is the pattern
// for any future secrets: generic-password items under the app's service)

enum Keychain {
    private static let service = "com.cj.progresso"

    static func save(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - OAuth plumbing

struct GoogleTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
}

enum GCalError: LocalizedError {
    case notConnected
    case noClientID
    case authFailed(String)
    case api(Int, String)
    case eventGone

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Google Calendar is not connected."
        case .noClientID: return "Paste your Google OAuth client ID in Settings first."
        case .authFailed(let s): return "Google sign-in failed: \(s)"
        case .api(let code, let s): return "Google Calendar error (\(code)): \(s)"
        case .eventGone: return "Event no longer exists."
        }
    }
}

enum PKCE {
    static func verifier() -> String {
        base64url(Data((0..<64).map { _ in UInt8.random(in: 0...255) }))
    }
    static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One-shot local HTTP listener for the OAuth installed-app loopback
/// redirect. Ignores stray requests (favicon etc.) and resolves exactly
/// once with the `code` query parameter.
final class LoopbackServer: @unchecked Sendable {
    private var listener: NWListener?
    private var codeContinuation: CheckedContinuation<String, Error>?

    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { cont in
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed, let port = listener.port?.rawValue {
                        resumed = true
                        cont.resume(returning: port)
                    }
                case .failed(let error):
                    if !resumed { resumed = true; cont.resume(throwing: error) }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }
            listener.start(queue: .main)
        }
    }

    func waitForCode(timeout: TimeInterval = 300) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            codeContinuation = cont
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, let pending = self.codeContinuation else { return }
                self.codeContinuation = nil
                self.stop()
                pending.resume(throwing: GCalError.authFailed("timed out waiting for the browser"))
            }
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let firstLine = request.components(separatedBy: "\r\n").first,
                  firstLine.hasPrefix("GET ") else {
                conn.cancel(); return
            }
            let path = firstLine.components(separatedBy: " ")[1]
            let comps = URLComponents(string: "http://127.0.0.1\(path)")
            let code = comps?.queryItems?.first(where: { $0.name == "code" })?.value
            let error = comps?.queryItems?.first(where: { $0.name == "error" })?.value

            guard code != nil || error != nil else {
                // favicon or noise — 404 it and keep waiting
                let resp = "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"
                conn.send(content: resp.data(using: .utf8),
                          completion: .contentProcessed { _ in conn.cancel() })
                return
            }

            let html = """
            <html><body style="font-family:-apple-system;text-align:center;margin-top:18%">
            <h2>Progresso is connected &#9749;</h2><p>You can close this tab and go back to the app.</p>
            </body></html>
            """
            let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: \(html.utf8.count)\r\n\r\n\(html)"
            conn.send(content: resp.data(using: .utf8),
                      completion: .contentProcessed { _ in conn.cancel() })

            if let pending = self.codeContinuation {
                self.codeContinuation = nil
                self.stop()
                if let code {
                    pending.resume(returning: code)
                } else {
                    pending.resume(throwing: GCalError.authFailed(error ?? "denied"))
                }
            }
        }
    }
}

// MARK: - The manager: auth state + Calendar API + read cache

/// A Google Calendar event as the dashboard shows it.
struct GCalEvent: Identifiable, Equatable {
    var id: String
    var title: String
    var date: String        // yyyy-MM-dd (start), used for sorting/labels
    var time: String        // "HH:mm" for timed events, "" for all-day
    var htmlLink: String?
    var isProgresso: Bool   // created by us (extendedProperties marker)
}

@MainActor
final class GCalManager: ObservableObject {
    static let shared = GCalManager()

    @Published var isConnected = false
    @Published var isConnecting = false
    @Published var events: [GCalEvent] = []
    @Published var lastError: String?
    /// Which Google account granted access — the primary calendar's title
    /// IS the account email. Surfaced in Settings so "wrong account"
    /// mistakes are visible instead of silent.
    @Published var accountEmail: String?
    /// Tickets whose last push failed — sidebar shows a retry affordance.
    @Published var failedSyncs: [String: String] = [:]   // ticket id → ticket title

    private var tokens: GoogleTokens?
    private let keychainAccount = "google-oauth"
    private let scope = "https://www.googleapis.com/auth/calendar.events"

    private init() {
        if let data = Keychain.load(account: keychainAccount),
           let stored = try? JSONDecoder().decode(GoogleTokens.self, from: data) {
            tokens = stored
            isConnected = true
            Task { await refreshEvents(days: 1) }   // populates accountEmail
        }
    }

    private var clientID: String {
        UserDefaults.standard.string(forKey: "gcalClientID")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    private var clientSecret: String {
        UserDefaults.standard.string(forKey: "gcalClientSecret")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    // MARK: Connect / disconnect

    func connect() async {
        guard !clientID.isEmpty else { lastError = GCalError.noClientID.localizedDescription; return }
        lastError = nil
        isConnecting = true
        defer { isConnecting = false }
        let server = LoopbackServer()
        do {
            let port = try await server.start()
            let redirect = "http://127.0.0.1:\(port)"
            let verifier = PKCE.verifier()

            var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            comps.queryItems = [
                .init(name: "client_id", value: clientID),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: scope),
                .init(name: "code_challenge", value: PKCE.challenge(for: verifier)),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),   // guarantees a refresh_token
            ]
            NSWorkspace.shared.open(comps.url!)

            let code = try await server.waitForCode()
            let fresh = try await exchangeToken(form: [
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": redirect,
                "code_verifier": verifier,
            ])
            store(fresh)
            isConnected = true
            await refreshEvents()
        } catch {
            server.stop()
            lastError = error.localizedDescription
        }
    }

    /// Local sign-out. Events already on the calendar stay (they're yours);
    /// they simply stop syncing.
    func disconnect() {
        if let t = tokens {   // best-effort server-side revoke
            var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke?token=\(t.refreshToken)")!)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req).resume()
        }
        Keychain.delete(account: keychainAccount)
        tokens = nil
        isConnected = false
        events = []
        failedSyncs = [:]
        lastError = nil
        accountEmail = nil
    }

    private func store(_ t: GoogleTokens) {
        tokens = t
        if let data = try? JSONEncoder().encode(t) {
            Keychain.save(data, account: keychainAccount)
        }
    }

    // MARK: Token lifecycle

    private func exchangeToken(form: [String: String]) async throws -> GoogleTokens {
        var full = form
        full["client_id"] = clientID
        if !clientSecret.isEmpty { full["client_secret"] = clientSecret }
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = full
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let access = json["access_token"] as? String else {
            let detail = (json["error_description"] as? String)
                ?? (json["error"] as? String) ?? "unknown"
            throw GCalError.authFailed(detail)
        }
        let expires = (json["expires_in"] as? Double) ?? 3600
        // Refresh responses omit refresh_token — keep the one we have.
        let refresh = (json["refresh_token"] as? String) ?? tokens?.refreshToken ?? ""
        return GoogleTokens(accessToken: access, refreshToken: refresh,
                            expiry: Date().addingTimeInterval(expires - 60))
    }

    private func validAccessToken() async throws -> String {
        guard let current = tokens else { throw GCalError.notConnected }
        if current.expiry > Date() { return current.accessToken }
        do {
            let fresh = try await exchangeToken(form: [
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
            ])
            store(fresh)
            return fresh.accessToken
        } catch {
            // Revoked/expired grant: drop to disconnected so the UI says so,
            // rather than failing every call quietly forever.
            if case GCalError.authFailed = error {
                Keychain.delete(account: keychainAccount)
                tokens = nil
                isConnected = false
                lastError = "Google session expired — reconnect in Settings."
            }
            throw error
        }
    }

    // MARK: Calendar API core

    @discardableResult
    private func api(_ method: String, _ path: String,
                     query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> [String: Any] {
        var comps = URLComponents(string: "https://www.googleapis.com/calendar/v3\(path)")!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200...299:
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        case 404, 410:
            throw GCalError.eventGone
        default:
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "request failed"
            throw GCalError.api(status, message)
        }
    }

    // MARK: Read: primary-calendar events for the dashboard window

    /// Dashboard's "upcoming" convenience — today through `days` ahead.
    func refreshEvents(days: Int = 14) async {
        let now = Calendar.current.startOfDay(for: Date())
        await refreshEvents(from: now, to: now.addingTimeInterval(Double(days) * 86_400))
    }

    /// The full calendar view fetches whatever month grid is on screen —
    /// callers pass the range directly instead of "days from now".
    func refreshEvents(from start: Date, to end: Date) async {
        guard isConnected else { return }
        let f = ISO8601DateFormatter()
        do {
            let json = try await api("GET", "/calendars/primary/events", query: [
                .init(name: "singleEvents", value: "true"),
                .init(name: "orderBy", value: "startTime"),
                .init(name: "timeMin", value: f.string(from: start)),
                .init(name: "timeMax", value: f.string(from: end)),
                .init(name: "maxResults", value: "250"),
            ])
            let items = json["items"] as? [[String: Any]] ?? []
            events = items.compactMap { Self.parseEvent($0) }
            accountEmail = json["summary"] as? String
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private static func parseEvent(_ item: [String: Any]) -> GCalEvent? {
        guard let id = item["id"] as? String,
              (item["status"] as? String) != "cancelled" else { return nil }
        let start = item["start"] as? [String: Any] ?? [:]
        var date = start["date"] as? String ?? ""
        var time = ""
        if date.isEmpty, let dt = start["dateTime"] as? String {
            date = String(dt.prefix(10))
            if let tIdx = dt.firstIndex(of: "T") {
                time = String(dt[dt.index(after: tIdx)...].prefix(5))
            }
        }
        guard !date.isEmpty else { return nil }
        let props = (item["extendedProperties"] as? [String: Any])?["private"] as? [String: Any]
        return GCalEvent(id: id,
                         title: (item["summary"] as? String) ?? "(no title)",
                         date: date, time: time,
                         htmlLink: item["htmlLink"] as? String,
                         isProgresso: props?["progressoTicket"] != nil)
    }

    // MARK: Write: ticket dates ⇄ events (Progresso data always wins)

    /// Push a ticket's dates to the calendar. Returns the ticket with its
    /// `gcalEventIDs` map updated (caller persists it). Creates, patches
    /// (recreating if the event was deleted in Google Calendar), and
    /// deletes ONLY events whose IDs we stored — nothing else is touched.
    func syncEvents(for ticket: Ticket) async throws -> Ticket {
        var t = ticket
        let dates: [(key: String, value: String?, label: String)] = [
            ("due", t.due, "due"),
            ("filming", t.filmingDate, "filming"),
            ("publish", t.publishDate, "publish"),
        ]
        for (key, value, label) in dates {
            let existing = t.gcalEventIDs[key]
            if t.gcalSync, let date = value, !date.isEmpty {
                let body = eventBody(t, date: date, label: label)
                if let existing {
                    do {
                        try await api("PATCH", "/calendars/primary/events/\(existing)", body: body)
                    } catch GCalError.eventGone {
                        t.gcalEventIDs[key] = try await create(body)
                    }
                } else {
                    t.gcalEventIDs[key] = try await create(body)
                }
            } else if let existing {
                // Date removed, sync switched off, or ticket deleted.
                do { try await api("DELETE", "/calendars/primary/events/\(existing)") }
                catch GCalError.eventGone {}   // already gone — fine
                t.gcalEventIDs.removeValue(forKey: key)
            }
        }
        failedSyncs.removeValue(forKey: t.id)
        return t
    }

    /// Fire-and-forget removal of a deleted ticket's events.
    func deleteEvents(ids: [String]) async {
        for id in ids {
            _ = try? await api("DELETE", "/calendars/primary/events/\(id)")
        }
    }

    func recordSyncFailure(_ t: Ticket, error: Error) {
        failedSyncs[t.id] = "\(t.title) — \(error.localizedDescription)"
        lastError = error.localizedDescription
    }

    private func create(_ body: [String: Any]) async throws -> String {
        let json = try await api("POST", "/calendars/primary/events", body: body)
        guard let id = json["id"] as? String else {
            throw GCalError.api(0, "event created but no id returned")
        }
        return id
    }

    private func eventBody(_ t: Ticket, date: String, label: String) -> [String: Any] {
        var description = "Progresso ticket"
        if !t.client.isEmpty { description += " · \(t.client)" }
        return [
            "summary": "\(t.title) — \(label)",
            "description": description,
            "start": ["date": date],
            "end": ["date": Self.plusOneDay(date)],    // all-day end is exclusive
            "extendedProperties": ["private": ["progressoTicket": t.id]],
        ]
    }

    private static func plusOneDay(_ ymd: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: ymd) else { return ymd }
        return f.string(from: d.addingTimeInterval(86_400))
    }
}
