import AppKit
import Foundation

/// Only the bundled installer runs with administrator authorization. No password
/// is collected by Hard Pause, and no arbitrary command enters this interface.
private actor InstallerWorker {
    func run(script: String) throws {
        var failure: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            throw InstallerError.failed("The system installation prompt could not open.")
        }
        _ = appleScript.executeAndReturnError(&failure)
        if let failure {
            let code = failure[NSAppleScript.errorNumber] as? Int ?? 0
            if code == -128 { throw InstallerError.cancelled }
            // The installer can print maintenance guidance; keep it out of normal UI.
            throw InstallerError.failed(
                "Installation did not finish. Your saved blocks were not reset. Try again or check Developer details.")
        }
    }
}

enum InstallerError: Error {
    case cancelled
    case failed(String)
}

enum ServiceInstaller {
    private static let worker = InstallerWorker()

    static func install(updateExisting: Bool = false, liveUpdate: Bool = false) async throws {
        guard let url = Bundle.main.url(forResource: "install-macos-service", withExtension: "sh") else {
            throw InstallerError.failed(
                "The installer is missing from this app. Download a complete copy of Hard Pause.")
        }
        let command =
            "/usr/bin/env SUDO_UID=\(getuid()) SUDO_USER=\(shellQuote(NSUserName())) /bin/bash \(shellQuote(url.path))"
        // Updates retain enrollment; they never grant new client permissions.
        let invocation = command + (liveUpdate ? " --live-update" : updateExisting ? " --update" : "")
        let script = "do shell script \(appleScriptQuote(invocation)) with administrator privileges"
        try await worker.run(script: script)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptQuote(_ value: String) -> String {
        "\""
            + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
