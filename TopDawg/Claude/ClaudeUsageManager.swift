import Foundation
import Combine
import SwiftUI

// MARK: - Pacing

enum ClaudeStatsPacingState {
    case wayUnder, under, optimal, fast, veryFast, critical

    var arrow: String {
        switch self {
        case .wayUnder: return "↓"
        case .under:    return "↘"
        case .optimal:  return "→"
        case .fast:     return "↗"
        case .veryFast: return "↑"
        case .critical: return "⬆"
        }
    }

    var color: Color {
        switch self {
        case .wayUnder:  return .blue
        case .under:     return Color(red: 0.45, green: 0.75, blue: 0.70)
        case .optimal:   return Color(red: 0.45, green: 0.75, blue: 0.70)
        case .fast:      return Color(red: 0.95, green: 0.70, blue: 0.35)
        case .veryFast:  return .orange
        case .critical:  return .red
        }
    }
}

struct ClaudeStatsPacingData {
    let paceRatio: Double
    let minutesUntilExhaustion: Double?
    let minutesRemaining: Double

    var state: ClaudeStatsPacingState {
        if paceRatio < 0.5 { return .wayUnder }
        if paceRatio < 0.8 { return .under }
        if paceRatio <= 1.2 { return .optimal }
        if paceRatio <= 1.5 { return .fast }
        if paceRatio <= 2.0 { return .veryFast }
        return .critical
    }

    var timeDelta: Double? {
        guard let exhaustion = minutesUntilExhaustion else { return nil }
        return exhaustion - minutesRemaining
    }

    var timeDeltaText: String? {
        guard let delta = timeDelta else { return nil }
        if delta > 0 {
            return "+\(formatDuration(delta)) buffer"
        } else {
            return "out in \(formatDuration(abs(delta)))"
        }
    }

    private func formatDuration(_ minutes: Double) -> String {
        if minutes < 60 { return "\(Int(minutes))m" }
        let hours = Int(minutes / 60)
        let mins = Int(minutes.truncatingRemainder(dividingBy: 60))
        if mins == 0 { return "\(hours)h" }
        return "\(hours)h \(mins)m"
    }

    static let unknown = ClaudeStatsPacingData(paceRatio: 1.0, minutesUntilExhaustion: nil, minutesRemaining: 0)
}

// MARK: - Usage Data

struct ClaudeUsageData {
    var sessionUtilization: Double = 0
    var weeklyUtilization: Double = 0
    var sonnetUtilization: Double = 0
    var opusUtilization: Double = 0
    var extraUsageUtilization: Double = 0
    var extraUsageCredits: Double = 0       // raw cents from API
    var extraUsageEnabled: Bool = false
    var extraUsageLimit: Double? = nil      // monthly cap in cents, nil = no cap
    var extraUsageResetsAt: Date? = nil     // next billing cycle (from subscription)
    var currencyCode: String = "USD"        // from subscription details

    var sessionResetsAt: Date?
    var weeklyResetsAt: Date?
    var sonnetResetsAt: Date?
    var opusResetsAt: Date?

    var lastUpdated: Date?
    var planDisplayName: String?

    var sessionPercentage: Double { sessionUtilization }
    var weeklyPercentage: Double { weeklyUtilization }
    var opusPercentage: Double { opusUtilization }
    var sonnetPercentage: Double { sonnetUtilization }

    /// Tokens consumed per hour in the current 5h session window. Nil until 5+ minutes elapsed.
    var sessionBurnRatePerHour: Double? {
        guard let resetsAt = sessionResetsAt, resetsAt > Date(), sessionUtilization > 0 else { return nil }
        let remainingSecs = resetsAt.timeIntervalSince(Date())
        let elapsedSecs   = 300.0 * 60.0 - remainingSecs   // 5h window
        guard elapsedSecs > 300 else { return nil }         // wait at least 5 min
        return sessionUtilization / (elapsedSecs / 3600.0)
    }

    var sessionPacing: ClaudeStatsPacingData {
        calculatePacing(utilization: sessionUtilization, resetsAt: sessionResetsAt, windowMinutes: 300)
    }

    var weeklyPacing: ClaudeStatsPacingData {
        calculatePacing(utilization: weeklyUtilization, resetsAt: weeklyResetsAt, windowMinutes: 10080)
    }

    private func calculatePacing(utilization: Double, resetsAt: Date?, windowMinutes: Double) -> ClaudeStatsPacingData {
        guard let resetsAt = resetsAt, resetsAt > Date() else { return .unknown }

        let now = Date()
        let minutesRemaining = resetsAt.timeIntervalSince(now) / 60.0
        let minutesElapsed = windowMinutes - minutesRemaining

        if utilization <= 0 && minutesElapsed < windowMinutes * 0.1 {
            return ClaudeStatsPacingData(paceRatio: 1.0, minutesUntilExhaustion: nil, minutesRemaining: minutesRemaining)
        }

        let idealUsage = (minutesElapsed / windowMinutes) * 100.0
        let paceRatio: Double
        if idealUsage <= 0 {
            paceRatio = utilization > 10 ? 2.5 : (utilization > 0 ? 1.5 : 1.0)
        } else {
            paceRatio = utilization / idealUsage
        }

        var minutesUntilExhaustion: Double? = nil
        if utilization > 0 && minutesElapsed > 0 {
            let rate = utilization / minutesElapsed
            if rate > 0 {
                minutesUntilExhaustion = (100.0 - utilization) / rate
            }
        }

        return ClaudeStatsPacingData(
            paceRatio: paceRatio,
            minutesUntilExhaustion: minutesUntilExhaustion,
            minutesRemaining: minutesRemaining
        )
    }
}

// MARK: - History

struct UsagePoint: Codable {
    let date: Date
    let session: Double
    let weekly: Double
}

// MARK: - Manager

final class ClaudeUsageManager: ObservableObject {
    @Published private(set) var isAuthenticated = false
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var usageData = ClaudeUsageData()
    @Published private(set) var history: [UsagePoint] = []

    private var sessionCookie: String?
    @Published private(set) var organizationId: String?
    private var refreshTimer: Timer?

    private static let sessionCookieKey  = "cn.sessionCookie"
    private static let organizationIdKey = "cn.organizationId"
    private static let historyKey        = "cn.usageHistory"
    private static let maxHistory        = 24

    init() {
        loadStoredCredentials()
        loadHistory()
    }

    private func loadHistory() {
        guard let data = UserDefaults.standard.data(forKey: Self.historyKey),
              let saved = try? JSONDecoder().decode([UsagePoint].self, from: data)
        else { return }
        history = saved
    }

    private func appendHistory(_ data: ClaudeUsageData) {
        guard data.sessionPercentage > 0 || data.weeklyPercentage > 0 else { return }
        let point = UsagePoint(date: Date(),
                               session: data.sessionPercentage,
                               weekly:  data.weeklyPercentage)
        history.append(point)
        if history.count > Self.maxHistory { history.removeFirst() }
        if let encoded = try? JSONEncoder().encode(history) {
            UserDefaults.standard.set(encoded, forKey: Self.historyKey)
        }
    }

    private func loadStoredCredentials() {
        sessionCookie = UserDefaults.standard.string(forKey: Self.sessionCookieKey)
        organizationId = UserDefaults.standard.string(forKey: Self.organizationIdKey)
        if sessionCookie != nil {
            isAuthenticated = true
            startPolling()
            Task { await fetchUsageData() }
        }
    }

    private func storeCredentials() {
        UserDefaults.standard.set(sessionCookie, forKey: Self.sessionCookieKey)
        UserDefaults.standard.set(organizationId, forKey: Self.organizationIdKey)
    }

    func logout() {
        sessionCookie = nil
        organizationId = nil
        isAuthenticated = false
        usageData = ClaudeUsageData()
        UserDefaults.standard.removeObject(forKey: Self.sessionCookieKey)
        UserDefaults.standard.removeObject(forKey: Self.organizationIdKey)
        stopPolling()
    }

    func setSession(cookie: String, organizationId: String?) {
        self.sessionCookie = cookie
        self.organizationId = organizationId
        self.isAuthenticated = true
        storeCredentials()
        startPolling()
        Task { await fetchUsageData() }
    }

    // MARK: - Fetching

    func fetchUsageData() async {
        guard let cookie = sessionCookie else {
            await MainActor.run { lastError = "Not authenticated" }
            return
        }

        await MainActor.run { isLoading = true; lastError = nil }

        do {
            if organizationId == nil {
                let orgId = try await fetchOrganizationId(cookie: cookie)
                await MainActor.run { self.organizationId = orgId }
                storeCredentials()
            }

            guard let orgId = await MainActor.run(body: { self.organizationId }) else {
                throw URLError(.badServerResponse)
            }

            async let usageTask = fetchUsage(cookie: cookie, orgId: orgId)
            async let subTask: SubscriptionInfo = fetchSubscriptionDetails(cookie: cookie, orgId: orgId)

            var usageResult = try await usageTask
            let subInfo = (try? await subTask) ?? SubscriptionInfo()
            usageResult.planDisplayName = subInfo.planName
            usageResult.extraUsageResetsAt = subInfo.nextChargeDate
            if let cur = subInfo.currency { usageResult.currencyCode = cur }
            let finalData = usageResult

            await MainActor.run {
                self.usageData = finalData
                self.appendHistory(finalData)
                self.isLoading = false
            }
        } catch {
            await MainActor.run {
                self.lastError = error.localizedDescription
                self.isLoading = false
                if let urlError = error as? URLError, urlError.code == .userAuthenticationRequired {
                    self.logout()
                }
            }
        }
    }

    private func fetchOrganizationId(cookie: String) async throws -> String {
        guard let url = URL(string: "https://claude.ai/api/organizations") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 || http.statusCode == 403 { throw URLError(.userAuthenticationRequired) }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }

        if let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
           let first = json.first,
           let uuid = first["uuid"] as? String { return uuid }
        throw URLError(.cannotParseResponse)
    }

    private func fetchUsage(cookie: String, orgId: String) async throws -> ClaudeUsageData {
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/usage") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 401 || http.statusCode == 403 { throw URLError(.userAuthenticationRequired) }

        return try parseUsageResponse(data)
    }

    struct SubscriptionInfo {
        var planName: String?
        var nextChargeDate: Date?
        var currency: String?
    }

    private func fetchSubscriptionDetails(cookie: String, orgId: String) async throws -> SubscriptionInfo {
        var info = SubscriptionInfo()
        guard let url = URL(string: "https://claude.ai/api/organizations/\(orgId)/subscription_details") else { return info }
        var request = URLRequest(url: url)
        request.setValue("sessionKey=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.2 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return info }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Plan name
            if let plan = json["plan"] as? [String: Any], let name = plan["name"] as? String { info.planName = formatPlanName(name) }
            else if let name = json["plan_name"] as? String { info.planName = formatPlanName(name) }
            else if let type = json["type"] as? String { info.planName = formatPlanName(type) }
            else if let tier = json["tier"] as? String { info.planName = formatPlanName(tier) }

            // Next charge date = extra usage reset
            if let ncd = json["next_charge_date"] as? String { info.nextChargeDate = Self.parseDate(ncd) }

            // Currency
            if let cur = json["currency"] as? String { info.currency = cur }
        }
        return info
    }

    private func formatPlanName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("max") {
            if lower.contains("200") { return "Max $200" }
            if lower.contains("100") { return "Max $100" }
            return "Max"
        }
        if lower.contains("pro") { return "Pro" }
        if lower.contains("free") { return "Free" }
        if lower.contains("team") { return "Team" }
        if lower.contains("enterprise") { return "Enterprise" }
        return name.capitalized
    }

    // Robust ISO-8601 parser: tries with fractional seconds, then without,
    // then DateFormatter fallbacks — handles any server format and DST correctly.
    private static func parseDate(_ string: String) -> Date? {
        // 1. ISO8601 with fractional seconds ("2026-04-08T13:30:00.000Z")
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: string) { return d }

        // 2. ISO8601 without fractional seconds ("2026-04-08T13:30:00Z")
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: string) { return d }

        // 3. DateFormatter fallbacks with explicit en_US_POSIX locale
        let df = DateFormatter()
        df.locale   = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(abbreviation: "UTC")
        for pattern in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZ",
            "yyyy-MM-dd'T'HH:mm:ssZZZZ",
        ] {
            df.dateFormat = pattern
            if let d = df.date(from: string) { return d }
        }
        return nil
    }

    private func parseUsageResponse(_ data: Data) throws -> ClaudeUsageData {
        var usage = ClaudeUsageData()
        usage.lastUpdated = Date()

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return usage }


        if let fh = json["five_hour"] as? [String: Any] {
            if let u = fh["utilization"] as? Double { usage.sessionUtilization = u }
            if let r = fh["resets_at"]  as? String  { usage.sessionResetsAt    = Self.parseDate(r) }
        }
        if let sd = json["seven_day"] as? [String: Any] {
            if let u = sd["utilization"] as? Double { usage.weeklyUtilization = u }
            if let r = sd["resets_at"]   as? String  { usage.weeklyResetsAt   = Self.parseDate(r) }
        }
        if let sn = json["seven_day_sonnet"] as? [String: Any] {
            if let u = sn["utilization"] as? Double { usage.sonnetUtilization = u }
            if let r = sn["resets_at"]   as? String  { usage.sonnetResetsAt   = Self.parseDate(r) }
        }
        if let op = json["seven_day_opus"] as? [String: Any] {
            if let u = op["utilization"] as? Double { usage.opusUtilization = u }
            if let r = op["resets_at"]   as? String  { usage.opusResetsAt   = Self.parseDate(r) }
        }
        if let ex = json["extra_usage"] as? [String: Any] {
            // utilization is often null; use used_credits (cents) as primary source
            let u = (ex["utilization"] as? Double)
                 ?? (ex["utilization"] as? Int).map { Double($0) }
            if let u = u { usage.extraUsageUtilization = u }

            let credits = (ex["used_credits"] as? Double)
                       ?? (ex["used_credits"] as? Int).map { Double($0) }
            if let c = credits { usage.extraUsageCredits = c }

            let limit = (ex["monthly_limit"] as? Double)
                     ?? (ex["monthly_limit"] as? Int).map { Double($0) }
            usage.extraUsageLimit = limit

            usage.extraUsageEnabled = (ex["is_enabled"] as? Bool) ?? false
        }

        return usage
    }

    // MARK: - Polling

    func startPolling(interval: TimeInterval = 300) {
        stopPolling()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { await self?.fetchUsageData() }
        }
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        Task { await fetchUsageData() }
    }
}
