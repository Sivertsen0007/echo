import Foundation

/// Persistent file log: everything the app writes to stdout/stderr (which
/// includes every NSLog call) is routed to ~/.jarvis-voice/logs/echo.log so
/// problems can be diagnosed after the fact without relaunching the app from
/// a terminal.
///
/// Rotation: at startup, if the log has grown past `maxBytes` it is moved to
/// echo.log.1 (replacing the previous one) and a fresh file is started.
enum LogFile {
    private static let maxBytes = 2_000_000

    static func setup() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".jarvis-voice/logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("echo.log")

        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > maxBytes {
            let old = dir.appendingPathComponent("echo.log.1")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }

        url.path.withCString { path in
            _ = freopen(path, "a", stderr)
            _ = freopen(path, "a", stdout)
        }
        setvbuf(stderr, nil, _IONBF, 0)
        setvbuf(stdout, nil, _IOLBF, 0)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        NSLog("=== Echo launched (v\(version), pid \(ProcessInfo.processInfo.processIdentifier)) ===")
    }
}
