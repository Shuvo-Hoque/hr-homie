import Foundation

/// Muslim prayer times for Kuala Lumpur (JAKIM zone WLY01) from JAKIM's official e-Solat timetable.
/// The current year ships in the app (Resources/takwim-WLY01-<year>.json); other years are downloaded once and kept in
/// Application Support, so it works offline. Times are KL local time whatever the Mac's time zone is.
@MainActor
final class PrayerTimes {
    struct Prayer {
        let key: String        // fajr, dhuhr, asr, maghrib, isha
        let name: String       // Subuh, Zohor (Jumaat on Fridays), Asar, Maghrib, Isyak
        let at: Date
        var id: String { "\(KL.day(at))|\(key)" }
        var time: String { KL.clock.string(from: at) }
    }

    nonisolated static let zone = "WLY01"
    nonisolated static let place = "Kuala Lumpur"
    private static let tz = KL.tz
    private static let order: [(String, String)] = [("fajr", "Subuh"), ("dhuhr", "Zohor"), ("asr", "Asar"),
                                                     ("maghrib", "Maghrib"), ("isha", "Isyak")]
    private static let months = ["Jan": 1, "Feb": 2, "Mac": 3, "Apr": 4, "Mei": 5, "Jun": 6, "Jul": 7, "Ogos": 8,
                                 "Sep": 9, "Okt": 10, "Nov": 11, "Dis": 12]

    /// "2026-10-15" -> ["fajr": "05:50:00", ...]
    private var days: [String: [String: String]] = [:]
    private var fetching = false

    init() {
        let year = Calendar.current.component(.year, from: Date())
        for y in [year, year + 1] { load(year: y) }
        refreshIfNeeded()
    }

    // MARK: lookups

    func prayers(on date: Date) -> [Prayer] {
        guard let day = days[Self.dayString(date)] else { return [] }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Self.tz
        let friday = cal.component(.weekday, from: date) == 6
        return Self.order.compactMap { key, name in
            guard let hms = day[key], let at = Self.date(Self.dayString(date), hms) else { return nil }
            return Prayer(key: key, name: friday && key == "dhuhr" ? "Jumaat" : name, at: at)
        }
    }

    /// The next prayer after `date` (today's or tomorrow's).
    func next(after date: Date) -> Prayer? {
        for offset in 0...2 {
            let d = date.addingTimeInterval(TimeInterval(offset) * 86_400)
            if let p = prayers(on: d).first(where: { $0.at > date }) { return p }
        }
        return nil
    }

    /// The prayer whose time has come: from `lead` before it until `window` after it.
    func current(at now: Date, lead: TimeInterval, window: TimeInterval) -> Prayer? {
        prayers(on: now).first { now >= $0.at.addingTimeInterval(-lead) && now < $0.at.addingTimeInterval(window) }
    }

    // MARK: timetable files

    private static var cacheDir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DeskBuddy", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private static func file(_ year: Int) -> String { "takwim-\(zone)-\(year).json" }

    private func load(year: Int) {
        let urls = [Self.cacheDir.appendingPathComponent(Self.file(year)),
                    Bundle.main.resourceURL!.appendingPathComponent(Self.file(year))]
        for url in urls {
            if let data = try? Data(contentsOf: url), ingest(data) { return }
        }
    }

    /// e-Solat JSON: {"prayerTime": [{"date": "15-Okt-2026", "fajr": "05:50:00", ...}], "status": "OK!"}
    @discardableResult
    private func ingest(_ data: Data) -> Bool {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["prayerTime"] as? [[String: Any]], !rows.isEmpty else { return false }
        for row in rows {
            guard let date = row["date"] as? String else { continue }
            let p = date.split(separator: "-")
            guard p.count == 3, let m = Self.months[String(p[1])], let d = Int(p[0]), let y = Int(p[2]) else { continue }
            var times: [String: String] = [:]
            for (key, _) in Self.order { if let t = row[key] as? String { times[key] = t } }
            days[String(format: "%04d-%02d-%02d", y, m, d)] = times
        }
        return true
    }

    /// Download this year's timetable if today is missing, and next year's from December on.
    func refreshIfNeeded() {
        let now = Date()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = Self.tz
        let year = cal.component(.year, from: now)
        var want: [Int] = []
        if days[Self.dayString(now)] == nil { want.append(year) }
        if cal.component(.month, from: now) == 12, days[String(format: "%04d-01-01", year + 1)] == nil { want.append(year + 1) }
        guard !want.isEmpty, !fetching else { return }
        fetching = true
        Task { [weak self] in
            for y in want {
                // e-Solat serves a year at a time; "duration" with explicit dates covers next year too
                let url = y == year
                    ? URL(string: "https://www.e-solat.gov.my/index.php?r=esolatApi/TakwimSolat&period=year&zone=\(Self.zone)")!
                    : URL(string: "https://www.e-solat.gov.my/index.php?r=esolatApi/TakwimSolat&period=duration&zone=\(Self.zone)")!
                var req = URLRequest(url: url, timeoutInterval: 30)
                if y != year {
                    req.httpMethod = "POST"
                    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    req.httpBody = "datestart=\(y)-01-01&dateend=\(y)-12-31".data(using: .utf8)
                }
                guard let (data, _) = try? await URLSession.shared.data(for: req) else { continue }
                await MainActor.run {
                    guard let self, self.ingest(data) else { return }
                    try? data.write(to: Self.cacheDir.appendingPathComponent(Self.file(y)))
                }
            }
            await MainActor.run { self?.fetching = false }
        }
    }

    static func dayString(_ d: Date) -> String { KL.day(d) }
    private static func date(_ day: String, _ hms: String) -> Date? { KL.full.date(from: "\(day) \(hms)") }
}

/// Dates and clock times in Kuala Lumpur time.
enum KL {
    static let tz = TimeZone(identifier: "Asia/Kuala_Lumpur")!
    static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = tz; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static let full: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.timeZone = tz; f.locale = Locale(identifier: "en_US_POSIX"); return f
    }()
    static let clock: DateFormatter = {
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = .none; f.timeZone = tz; return f
    }()
    static func day(_ d: Date) -> String { dayFmt.string(from: d) }
}
