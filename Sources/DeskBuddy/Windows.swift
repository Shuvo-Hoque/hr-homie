import AppKit

/// Other apps' windows, read with CGWindowList (window bounds need no permission). Frames are in Cocoa screen
/// coordinates (origin at the bottom-left of the main screen).
enum Windows {
    struct Info { let id: CGWindowID; let frame: NSRect }

    /// The front window of the app the user is working in, if it's a normal, reasonably big window.
    static func front() -> Info? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return nil }
        for w in list {                                   // front to back
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0.5,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let f = frame(of: w), f.width >= 600, f.height >= 300 else { continue }
            return Info(id: id, frame: f)
        }
        return nil
    }

    /// Where that window is now; nil once it's closed, minimised or on another Space.
    static func frame(_ id: CGWindowID) -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let w = list.first, (w[kCGWindowIsOnscreen as String] as? Bool) == true else { return nil }
        return frame(of: w)
    }

    private static func frame(of w: [String: Any]) -> NSRect? {
        guard let b = w[kCGWindowBounds as String] as? NSDictionary,
              let cg = CGRect(dictionaryRepresentation: b as CFDictionary),
              let main = NSScreen.screens.first else { return nil }
        // CG: origin top-left of the main screen, y down. Cocoa: origin bottom-left, y up.
        return NSRect(x: cg.minX, y: main.frame.height - cg.maxY, width: cg.width, height: cg.height)
    }
}
