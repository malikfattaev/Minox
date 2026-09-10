import Foundation
import Security

/// Настоящие лимиты Claude берём там же, где их берёт /status, — из /api/oauth/usage.
/// Локальные логи для этого не годятся: лимит считается по всему аккаунту,
/// включая другие устройства и claude.ai, а логи видят только эту машину.
enum ClaudeUsageAPI {
    struct Limits {
        let sessionPercent: Double
        let sessionResetsAt: Date?
        let weeklyPercent: Double
        let weeklyResetsAt: Date?
    }

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    /// Своя пара токенов (scripts/claude-auth.py). Приоритетный источник:
    /// обновляем её сами, авторизацию Claude Code не задеваем.
    private static let ownService = "Minox-claude-oauth"
    /// Запасной источник — токен Claude Code. Только чтение, без refresh:
    /// его refresh-токен ротируется, и обновлять его вторым процессом опасно.
    private static let claudeCodeService = "Claude Code-credentials"

    private static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// Cloudflare перед platform.claude.com отбивает запросы без внятного User-Agent.
    private static let userAgent = "claude-cli/2.1.257 (external, cli)"

    static func fetch() async -> Limits? {
        if let token = await ownAccessToken(), let limits = await fetch(with: token) {
            return limits
        }
        if let token = claudeCodeToken(), let limits = await fetch(with: token) {
            return limits
        }
        return nil
    }

    private static func fetch(with token: String) async -> Limits? {

        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return nil }
            guard http.statusCode == 200 else {
                let reason = String(decoding: data.prefix(160), as: UTF8.self)
                NSLog("Minox: /api/oauth/usage вернул \(http.statusCode) — \(reason)")
                return nil
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

            let session = window(json["five_hour"])
            let weekly = window(json["seven_day"])
            guard let session else { return nil }
            return Limits(
                sessionPercent: session.percent,
                sessionResetsAt: session.resetsAt,
                weeklyPercent: weekly?.percent ?? 0,
                weeklyResetsAt: weekly?.resetsAt
            )
        } catch {
            NSLog("Minox: запрос лимитов не прошёл — \(error.localizedDescription)")
            return nil
        }
    }

    private static func window(_ value: Any?) -> (percent: Double, resetsAt: Date?)? {
        guard let dict = value as? [String: Any],
              let percent = (dict["utilization"] as? NSNumber)?.doubleValue
        else { return nil }
        let resets = (dict["resets_at"] as? String).flatMap(parseDate)
        return (percent, resets)
    }

    /// ISO8601DateFormatter не Sendable, поэтому создаём его на месте —
    /// дат тут две на запрос, экономить не на чем.
    private static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    // MARK: - Keychain

    /// Токен обновляет сам Claude Code и кладёт обратно в связку ключей.
    /// Мы только читаем — свой refresh не делаем, чтобы не сломать его авторизацию.
    private struct StoredTokens {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Double
    }

    /// Свой токен, при необходимости обновлённый. Ротацию refresh-токена
    /// храним в своей же записи, поэтому пересечься с Claude Code невозможно.
    private static func ownAccessToken() async -> String? {
        guard let tokens = readOwnTokens() else { return nil }
        // Минута запаса, чтобы не попасть в протухание прямо в полёте.
        if Date().timeIntervalSince1970 * 1000 < tokens.expiresAt - 60_000 {
            return tokens.accessToken
        }
        guard let refreshed = await refresh(tokens.refreshToken) else {
            NSLog("Minox: не удалось обновить свой токен — нужен scripts/claude-auth.py")
            return nil
        }
        writeOwnTokens(refreshed)
        return refreshed.accessToken
    }

    private static func refresh(_ refreshToken: String) async -> StoredTokens? {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ])
        request.timeoutInterval = 20

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else { return nil }

        let expiresIn = (json["expires_in"] as? NSNumber)?.doubleValue ?? 28_800
        return StoredTokens(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String ?? refreshToken,
            expiresAt: (Date().timeIntervalSince1970 + expiresIn) * 1000
        )
    }

    private static func readOwnTokens() -> StoredTokens? {
        guard let data = keychainValue(service: ownService),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["accessToken"] as? String,
              let refresh = json["refreshToken"] as? String
        else { return nil }
        return StoredTokens(
            accessToken: access,
            refreshToken: refresh,
            expiresAt: (json["expiresAt"] as? NSNumber)?.doubleValue ?? 0
        )
    }

    private static func writeOwnTokens(_ tokens: StoredTokens) {
        let payload: [String: Any] = [
            "accessToken": tokens.accessToken,
            "refreshToken": tokens.refreshToken,
            "expiresAt": tokens.expiresAt
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }

        let match: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ownService
        ]
        let status = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = match
            insert[kSecValueData as String] = data
            SecItemAdd(insert as CFDictionary, nil)
        } else if status != errSecSuccess {
            NSLog("Minox: не смог сохранить обновлённый токен (\(status))")
        }
    }

    /// Токен Claude Code. Обновляет его только сам Claude Code — мы не пишем
    /// в эту запись, чтобы не поломать его авторизацию ротацией refresh-токена.
    private static func claudeCodeToken() -> String? {
        guard let data = keychainValue(service: claudeCodeService),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String
        else { return nil }

        if let expiresAt = (oauth["expiresAt"] as? NSNumber)?.doubleValue,
           Date().timeIntervalSince1970 >= expiresAt / 1000 {
            NSLog("Minox: токен Claude Code протух — нужен свой токен через claude setup-token")
            return nil
        }
        return token
    }

    private static func keychainValue(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }
}
