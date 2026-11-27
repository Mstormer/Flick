import AppKit

// The bundle identifier moved from app.flick.player to com.amplifyinteractions.flick (0.2.9): bring the saved speed, resume
// positions and settings over once, without overwriting anything already set under the new identifier.
if Bundle.main.bundleIdentifier == "com.amplifyinteractions.flick", !UserDefaults.standard.bool(forKey: "migratedFromAppFlickPlayer") {
    for (k, v) in UserDefaults.standard.persistentDomain(forName: "app.flick.player") ?? [:] where UserDefaults.standard.object(forKey: k) == nil {
        UserDefaults.standard.set(v, forKey: k)
    }
    UserDefaults.standard.set(true, forKey: "migratedFromAppFlickPlayer")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
