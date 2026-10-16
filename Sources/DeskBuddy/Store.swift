import Foundation

/// The three things the buddy reminds people about. Each can be switched on or off.
enum Kind: String, CaseIterable {
    case water, eyes, move, prayer

    var menuTitle: String {
        switch self {
        case .water: return "💧 Water"
        case .eyes: return "👀 Eye Breaks"
        case .move: return "🚶 Movement Breaks"
        case .prayer: return "🕌 Prayer Times"
        }
    }
}

/// Settings, today's water log and the goal streak, kept in UserDefaults.
@MainActor
final class Store {
    private let d = UserDefaults.standard

    private func int(_ key: String, _ fallback: Int) -> Int { d.object(forKey: key) as? Int ?? fallback }

    func isEnabled(_ k: Kind) -> Bool { d.object(forKey: "enabled.\(k.rawValue)") as? Bool ?? true }
    func setEnabled(_ k: Kind, _ on: Bool) { d.set(on, forKey: "enabled.\(k.rawValue)") }
    /// Once a day he peeks in from the screen edge, waves and ducks away.
    var peekEnabled: Bool { get { d.object(forKey: "enabled.peek") as? Bool ?? true } set { d.set(newValue, forKey: "enabled.peek") } }
    var lastPeekDay: String? { get { d.string(forKey: "lastPeekDay") } set { d.set(newValue, forKey: "lastPeekDay") } }
    var today: String { day() }
    /// Where he shows up: "corner", "mix" (sometimes on the front window) or "window" (on the window whenever he can).
    var placement: String { get { d.string(forKey: "placement") ?? "mix" } set { d.set(newValue, forKey: "placement") } }
    /// Minutes before each prayer time to remind (0 = at the time).
    var prayerLeadMinutes: Int { get { int("prayerLeadMinutes", 0) } set { d.set(newValue, forKey: "prayerLeadMinutes") } }
    /// Prayers already announced (ids like "2026-10-15|asr"), so each one comes once.
    var prayersShown: [String] { get { d.stringArray(forKey: "prayersShown") ?? [] } set { d.set(Array(newValue.suffix(20)), forKey: "prayersShown") } }

    /// Minutes between water reminders.
    var intervalMinutes: Int { get { int("intervalMinutes", 30) } set { d.set(newValue, forKey: "intervalMinutes") } }
    /// Minutes of continuous screen use before an eye break (the 20-20-20 rule).
    var eyesMinutes: Int { get { int("eyesMinutes", 20) } set { d.set(newValue, forKey: "eyesMinutes") } }
    /// Minutes of continuous use before a movement break.
    var moveMinutes: Int { get { int("moveMinutes", 60) } set { d.set(newValue, forKey: "moveMinutes") } }
    /// Millilitres logged per "Okay": a few sips, not a full glass.
    var amountML: Int { get { int("amountML", 125) } set { d.set(newValue, forKey: "amountML") } }
    var goalML: Int { get { int("goalML", 2000) } set { d.set(newValue, forKey: "goalML") } }
    /// Seconds "Not Now" puts a reminder off by.
    var snoozeSeconds: Int { get { int("snoozeSeconds", 10) } set { d.set(newValue, forKey: "snoozeSeconds") } }
    var buddyScale: Double { get { d.object(forKey: "buddyScale") as? Double ?? 1.0 } set { d.set(newValue, forKey: "buddyScale") } }
    var soundOn: Bool { get { d.object(forKey: "soundOn") as? Bool ?? true } set { d.set(newValue, forKey: "soundOn") } }
    var pausedUntil: Date? { get { d.object(forKey: "pausedUntil") as? Date } set { d.set(newValue, forKey: "pausedUntil") } }
    var hasLaunchedBefore: Bool { get { d.bool(forKey: "hasLaunchedBefore") } set { d.set(newValue, forKey: "hasLaunchedBefore") } }

    // MARK: today's intake (resets when the date changes)

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    private func day(_ offset: Int = 0) -> String {
        Store.dayFormat.string(from: Calendar.current.date(byAdding: .day, value: offset, to: Date())!)
    }

    var todayML: Int {
        rollDayIfNeeded()
        return int("todayML", 0)
    }

    func rollDayIfNeeded() {
        if d.string(forKey: "day") != day() {
            d.set(day(), forKey: "day")
            d.set(0, forKey: "todayML")
        }
    }

    func logDrink() {
        d.set(todayML + amountML, forKey: "todayML")
    }

    func resetToday() {
        d.set(day(), forKey: "day")
        d.set(0, forKey: "todayML")
    }

    // MARK: streak: days in a row the goal was reached

    /// Current streak: counts while the goal was last met today or yesterday.
    var streak: Int {
        let last = d.string(forKey: "lastGoalDay")
        return last == day() || last == day(-1) ? int("goalStreak", 0) : 0
    }

    func recordGoalMet() {
        let last = d.string(forKey: "lastGoalDay")
        guard last != day() else { return }
        d.set(last == day(-1) ? int("goalStreak", 0) + 1 : 1, forKey: "goalStreak")
        d.set(day(), forKey: "lastGoalDay")
    }
}

/// The app's name, from Info.plist (CFBundleDisplayName), for the menu, tooltip and bubble.
let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "HR Homie"

/// "2 L", "1.5 L"
func litres(_ ml: Int) -> String {
    let l = Double(ml) / 1000
    return l == l.rounded() ? "\(Int(l)) L" : String(format: "%.1f L", l)
}
