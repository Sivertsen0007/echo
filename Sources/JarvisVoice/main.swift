import Cocoa

LogFile.setup()

// Single-instance guard: a second copy (launchd + a manual open, or a
// build-dir binary alongside the installed app) would register a second
// hotkey tap and insert every dictation twice.
let myPid = ProcessInfo.processInfo.processIdentifier
if let bundleId = Bundle.main.bundleIdentifier,
   NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
       .contains(where: { $0.processIdentifier != myPid }) {
    NSLog("Another Echo instance is already running - exiting")
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
