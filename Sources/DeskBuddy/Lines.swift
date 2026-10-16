import Foundation

/// How far a drink just took today's total.
enum Milestone { case none, half, goal, beyond }

/// What the buddy says. Titles stay put; the line under them rotates and follows the moment (Monday morning,
/// Friday afternoon, after lunch, late evening, how the day's water is going), so he doesn't repeat himself.
enum Lines {
    struct Context {
        var intervalMinutes = 30, amountML = 125, todayML = 0, goalML = 2000
        var eyesMinutes = 20, moveMinutes = 60
        var snoozeCount = 0, snoozeSeconds = 10, streak = 0
        var nextTime = ""
        var prayerName = "", prayerTime = ""
        var now = Date()
    }

    static func title(_ k: Kind) -> String {
        switch k {
        case .water: return "Time to drink some water 💧"
        case .eyes: return "Time to rest your eyes 👀"
        case .move: return "Time for a short walk 🚶"
        case .prayer: return "It's prayer time, let's pray! 🕌"
        }
    }

    // MARK: asking

    static func ask(_ k: Kind, _ c: Context) -> String {
        if k == .prayer {
            let (n, t) = (c.prayerName, c.prayerTime)
            if c.snoozeCount > 0 { return keepTail("Still time for \(n) (\(t)). Let's go 🙂") }
            if n == "Jumaat" { return keepTail("Jumaat at \(t). Let's not be late 🕌") }
            return keepTail(["\(n) at \(t) in \(PrayerTimes.place).", "\(n) at \(t). Let's go together 🤲",
                             "\(n) at \(t). Your work will wait 🙂"].randomElement()!)
        }
        if c.snoozeCount >= 2 { return "You said “not now” \(c.snoozeCount) times. Now is now 😤" }
        let cal = Calendar.current
        let hour = cal.component(.hour, from: c.now), weekday = cal.component(.weekday, from: c.now)   // 1 = Sunday
        var timely: [String] = []
        var usual: [String]
        switch k {
        case .water:
            if weekday == 2 && hour < 12 { timely.append("New week, fresh glass 💧") }
            if weekday == 6 && hour >= 16 { timely.append("Last sips of the week 🎉") }
            if hour < 10 { timely.append("Good morning! Start the day with some water ☀️") }
            if hour == 13 || hour == 14 { timely.append("Post-lunch slump? Water helps 💪") }
            if hour >= 19 { timely.append("Still working? At least stay hydrated 🌙") }
            if c.goalML > 0, c.todayML * 2 >= c.goalML, c.todayML < c.goalML {
                timely.append("Over halfway to \(litres(c.goalML)) today. Keep going!")
            }
            let plain = "It's been \(c.intervalMinutes)\u{00A0}minutes. Have about \(c.amountML)\u{00A0}ml now."
            usual = [plain, plain,
                     "Your brain is about 75% water. Top it up 🧠",
                     "Coffee doesn't count. I checked ☕️",
                     "Hydrated code has fewer bugs. Probably 🐛",
                     "Even your plants got watered today 🌱",
                     "I walked all the way over here. Just a few sips? 🥺",
                     "Small sips, big difference."]
        case .eyes:
            if hour >= 19 { timely.append("Late screen time. Give your eyes 20 seconds off 🌙") }
            let plain = "\(c.eyesMinutes)\u{00A0}minutes on screen. Look at something far away for 20\u{00A0}seconds."
            usual = [plain, plain,
                     "Find the farthest thing you can see and stare at it for 20 seconds 🔭",
                     "Your eyes have been doing close-up work. Let them zoom out 👀",
                     "Blink a few times, then look out of the window 🪟"]
        case .prayer:
            usual = []
        case .move:
            if hour == 13 || hour == 14 { timely.append("Walk off that lunch. Two minutes is enough 🥗") }
            if weekday == 6 && hour >= 16 { timely.append("Friday stroll? You've earned it 🎉") }
            let plain = "You've been at it for \(c.moveMinutes)\u{00A0}minutes. Stand up and walk for 2–3 minutes."
            usual = [plain, plain,
                     "Refill your water on the way. Two birds 🐦",
                     "Your chair will still be here. Promise 🪑",
                     "A lap around the office does wonders for the next hour 🔁"]
        }
        if let line = timely.randomElement(), Double.random(in: 0..<1) < 0.7 { return keepTail(line) }
        return keepTail(usual.randomElement()!)
    }

    /// Glue the last word to what precedes it, so a wrapping line never leaves an emoji alone on the last row.
    static func keepTail(_ s: String) -> String {
        guard let r = s.range(of: " ", options: .backwards) else { return s }
        return s.replacingCharacters(in: r, with: "\u{00A0}")
    }

    // MARK: after "Okay"

    static func water(_ c: Context, _ m: Milestone) -> (String, String) {
        switch m {
        case .goal:
            return ("Goal reached! 🎉", c.streak > 1 ? "\(litres(c.goalML)) today. 🔥 \(c.streak) days in a row!"
                                                     : "\(litres(c.goalML)) today. Your body says thanks 💙")
        case .half:
            return ("Halfway there! 🙌", "\(c.todayML) ml of \(litres(c.goalML)). Next sips at \(c.nextTime).")
        case .beyond:
            return ("Overachiever! \(c.todayML) ml 🏆", "Next sips at \(c.nextTime).")
        case .none:
            return ("Nice! \(c.todayML) ml today ✅", ["Next sips at \(c.nextTime).",
                                                     "Cheers 🥂 Next sips at \(c.nextTime).",
                                                     "Your kidneys say thanks. Next round at \(c.nextTime)."].randomElement()!)
        }
    }

    static let eyesDone = ("Eyes rested ✅", "See you in a while.")
    static let eyesSkipped = ("Skipped? 🥲", "Your eyes deserved that.")
    static let moveDone = ("Let's go! 🚶", "See you in a few minutes. Bring water back 💧")

    static func prayerGo(_ c: Context) -> (String, String) { ("Let's go! 🤲", "See you after \(c.prayerName).") }

    static func prayerLater(_ c: Context) -> (String, String) {
        ("Okay… 😔", "Don't be too late. I'll come back in \(max(c.snoozeSeconds, 300) / 60) minutes.")
    }

    static let cheers = ("Cheers! 🥂", "To your health 💧")

    // MARK: picked up, dropped, sitting on a window

    static func landed(windowGone: Bool) -> String {
        if windowGone { return ["Hey! Where did my window go?! 😱", "You closed it with me on it? 😤"].randomElement()! }
        return ["Put me down gently next time 😤", "Was that really necessary? 🤨", "My dignity… 😵‍💫",
                "I'm not a toy! …OK, that was a bit fun 😄"].randomElement()!
    }

    // MARK: after "Not Now": more dramatic every time

    static func snoozed(_ c: Context) -> (String, String) {
        let back = c.snoozeSeconds < 60 ? "\(c.snoozeSeconds) seconds" : "\(c.snoozeSeconds / 60) minutes"
        let lines: [(String, String)] = [
            ("Fine 🙄", "Back in \(back)."),
            ("Again? 🥲", "OK… \(back). I'm counting."),
            ("Not now, not now… 😤", "Back in \(back). Bringing a bigger glass."),
            ("I'm not mad. I'm disappointed 😔", "\(back). Think about what you've done."),
            ("You can't escape me 👀", "I'll be back in \(back). I always come back."),
        ]
        let (t, m) = lines[min(max(c.snoozeCount - 1, 0), lines.count - 1)]
        return (t, keepTail(m))
    }
}
