import EventKit
import Foundation
import UserNotifications

struct InterviewImportSuggestion: Equatable, Sendable {
    let sourceText: String
    let company: String
    let role: String
    let scheduledAt: Date?
    let timeZoneIdentifier: String
    let meetingURL: String?
}

enum InterviewImportParser {
    static let maximumCharacters = 30_000

    static func parse(_ rawText: String, now: Date = .now) -> InterviewImportSuggestion {
        let text = String(rawText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maximumCharacters))
        let timeZone = detectedTimeZone(in: text) ?? .current
        let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.date.rawValue
                | NSTextCheckingResult.CheckingType.link.rawValue
        )
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = detector?.matches(in: text, options: [], range: range) ?? []
        let date = matches.compactMap(\.date).first { $0 >= now.addingTimeInterval(-300) }
        let url = matches.compactMap(\.url).first { candidate in
            guard let scheme = candidate.scheme?.lowercased() else { return false }
            return scheme == "https" || scheme == "http"
        }
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        let company = labeledValue(in: lines, labels: ["компания", "company", "работодатель"])
        let role = labeledValue(in: lines, labels: ["вакансия", "роль", "position", "role"])

        return InterviewImportSuggestion(
            sourceText: text,
            company: String((company ?? "").prefix(200)),
            role: String((role ?? "").prefix(200)),
            scheduledAt: date,
            timeZoneIdentifier: timeZone.identifier,
            meetingURL: url?.absoluteString
        )
    }

    static func validatedMeetingURL(_ rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else { return nil }
        return components.url
    }

    private static func labeledValue(in lines: [String], labels: [String]) -> String? {
        for line in lines {
            let lowered = line.lowercased()
            for label in labels {
                for separator in [":", "—", "-"] where lowered.hasPrefix(label + separator) || lowered.hasPrefix(label + " " + separator) {
                    guard let separatorRange = line.range(of: separator) else { continue }
                    let value = line[separatorRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty { return value }
                }
            }
        }
        return nil
    }

    private static func detectedTimeZone(in text: String) -> TimeZone? {
        let upper = text.uppercased()
        if upper.contains("МСК") || upper.contains("MSK") { return TimeZone(identifier: "Europe/Moscow") }
        let pattern = #"(?:UTC|GMT)\s*([+-])\s*(\d{1,2})(?::?(\d{2}))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: upper, range: NSRange(upper.startIndex..., in: upper)),
              let signRange = Range(match.range(at: 1), in: upper),
              let hourRange = Range(match.range(at: 2), in: upper),
              let hours = Int(upper[hourRange]) else { return nil }
        let minutes: Int
        if match.range(at: 3).location != NSNotFound,
           let minuteRange = Range(match.range(at: 3), in: upper) {
            minutes = Int(upper[minuteRange]) ?? 0
        } else {
            minutes = 0
        }
        guard hours <= 14, minutes < 60 else { return nil }
        let multiplier = upper[signRange] == "+" ? 1 : -1
        return TimeZone(secondsFromGMT: multiplier * (hours * 3_600 + minutes * 60))
    }
}

enum InterviewSchedulePolicy {
    static let reminderLeadTime: TimeInterval = 15 * 60

    static func reminderIdentifier(eventID: UUID) -> String { "quickcue.interview.\(eventID.uuidString)" }

    static func calendarNeedsUpdate(_ event: InterviewEventRecord) -> Bool {
        guard event.calendarEventIdentifier != nil else { return false }
        return event.calendarScheduledAt != event.scheduledAt
    }

    static func requireAccess(_ granted: Bool, forCalendar: Bool) throws {
        guard !granted else { return }
        if forCalendar { throw InterviewScheduleServiceError.calendarDenied }
        throw InterviewScheduleServiceError.notificationsDenied
    }

    static func validationMessage(
        scheduledAt: Date,
        timeZoneIdentifier: String,
        meetingURL: String,
        now: Date = .now
    ) -> String? {
        guard scheduledAt > now else { return "Выберите будущее время интервью." }
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { return "Выберите корректный часовой пояс." }
        if !meetingURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           InterviewImportParser.validatedMeetingURL(meetingURL) == nil {
            return "Ссылка должна быть обычным http/https-адресом без логина и пароля."
        }
        return nil
    }

    static func isDuplicate(
        company: String,
        role: String,
        scheduledAt: Date,
        existing: [InterviewEventRecord],
        excludingID: UUID? = nil
    ) -> Bool {
        let normalizedCompany = normalize(company)
        let normalizedRole = normalize(role)
        return existing.contains { event in
            event.id != excludingID
                && abs(event.scheduledAt.timeIntervalSince(scheduledAt)) < 5 * 60
                && normalize(event.company) == normalizedCompany
                && normalize(event.role) == normalizedRole
        }
    }

    static func dateComponents(for date: Date, timeZoneIdentifier: String) -> DateComponents? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .timeZone], from: date)
    }

    static func displayDate(_ date: Date, timeZoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .long
        formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        return formatter.string(from: date)
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

enum InterviewScheduleServiceError: LocalizedError, Equatable {
    case calendarDenied
    case notificationsDenied
    case pastReminder
    case noCalendar

    var errorDescription: String? {
        switch self {
        case .calendarDenied: "Доступ к календарю не разрешён. Карточка QuickCue осталась сохранена локально."
        case .notificationsDenied: "Уведомления не разрешены. Карточка QuickCue осталась сохранена локально."
        case .pastReminder: "До интервью меньше 15 минут. Выберите будущее время или откройте карточку вручную."
        case .noCalendar: "На iPhone не найден календарь для нового события."
        }
    }
}

@MainActor
final class InterviewSystemScheduleService {
    private let eventStore: EKEventStore
    private let notificationCenter: UNUserNotificationCenter

    init(
        eventStore: EKEventStore = EKEventStore(),
        notificationCenter: UNUserNotificationCenter = .current()
    ) {
        self.eventStore = eventStore
        self.notificationCenter = notificationCenter
    }

    func addToCalendar(_ event: InterviewEventRecord) async throws -> String {
        let granted = try await eventStore.requestFullAccessToEvents()
        try InterviewSchedulePolicy.requireAccess(granted, forCalendar: true)
        let item: EKEvent
        if let identifier = event.calendarEventIdentifier,
           let existing = eventStore.event(withIdentifier: identifier) {
            item = existing
        } else {
            guard let calendar = eventStore.defaultCalendarForNewEvents else {
                throw InterviewScheduleServiceError.noCalendar
            }
            item = EKEvent(eventStore: eventStore)
            item.calendar = calendar
        }
        item.title = [event.company, event.role].filter { !$0.isEmpty }.joined(separator: " — ")
        item.startDate = event.scheduledAt
        item.endDate = event.scheduledAt.addingTimeInterval(60 * 60)
        item.timeZone = TimeZone(identifier: event.timeZoneIdentifier)
        item.notes = event.notes.isEmpty ? "Создано в QuickCue" : event.notes
        item.url = event.meetingURL.flatMap(InterviewImportParser.validatedMeetingURL)
        try eventStore.save(item, span: .thisEvent, commit: true)
        guard let identifier = item.eventIdentifier else { throw InterviewScheduleServiceError.noCalendar }
        return identifier
    }

    func scheduleReminder(for event: InterviewEventRecord, now: Date = .now) async throws -> String {
        let reminderDate = event.scheduledAt.addingTimeInterval(-InterviewSchedulePolicy.reminderLeadTime)
        guard reminderDate > now else { throw InterviewScheduleServiceError.pastReminder }
        let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
        try InterviewSchedulePolicy.requireAccess(granted, forCalendar: false)
        let identifier = InterviewSchedulePolicy.reminderIdentifier(eventID: event.id)
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
        let content = UNMutableNotificationContent()
        // Keep company, role and notes off the lock screen by default.
        content.title = "Скоро интервью"
        content.body = "Откройте подготовленный контекст QuickCue."
        content.sound = .default
        content.userInfo = ["quickCueInterviewID": event.id.uuidString]
        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: max(1, reminderDate.timeIntervalSince(now)),
            repeats: false
        )
        try await notificationCenter.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        return identifier
    }

    func removeReminder(identifier: String?) {
        guard let identifier else { return }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

enum InterviewNavigationRequestStore {
    static let notification = Notification.Name("QuickCueInterviewNavigationRequest")
    private static let defaultsKey = "navigation.pendingInterviewID.v1"

    static func request(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: defaultsKey)
        NotificationCenter.default.post(name: notification, object: nil)
    }

    static func consume() -> UUID? {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey), let id = UUID(uuidString: raw) else {
            return nil
        }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return id
    }

    static func id(from url: URL) -> UUID? {
        guard url.scheme?.lowercased() == "quickcue", url.host?.lowercased() == "interview" else { return nil }
        let value = url.pathComponents.last ?? ""
        return UUID(uuidString: value)
    }
}
