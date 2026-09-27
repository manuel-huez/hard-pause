import AppKit
import Darwin
import Foundation
import Security

/// Repairs only a GUI whose executable disappeared during a signed Sparkle replacement.
enum AppUpdateRecovery {
    static let relaunchArgument = "--hard-pause-update-recovery"
    static let installedApp = URL(fileURLWithPath: "/Applications/HardPause.app")

    struct Replacement: Equatable {
        let app: URL
        let worker: URL
        let codeHash: Data
    }

    static func replacement() -> Replacement? {
        guard Bundle.main.bundleURL.standardizedFileURL == installedApp,
            Bundle.main.bundleIdentifier == "org.hardpause.app",
            currentImageWasRemoved(),
            let bundle = Bundle(url: installedApp),
            bundle.bundleIdentifier == "org.hardpause.app",
            let build = UInt64(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
            let currentBuild = UInt64(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""),
            build >= currentBuild,
            let codeHash = validatedHash(at: installedApp, requirement: BrowserWorkerIdentity.appRequirement)
        else { return nil }
        let workerBundle = installedApp.appendingPathComponent("Contents/Resources/HardPauseBrowserWorker.app")
        guard validatedHash(at: workerBundle, requirement: BrowserWorkerIdentity.workerRequirement) != nil else {
            return nil
        }
        return Replacement(
            app: installedApp,
            worker: workerBundle.appendingPathComponent("Contents/MacOS/HardPauseBrowserWorker"),
            codeHash: codeHash
        )
    }

    static func currentImageWasRemoved() -> Bool {
        var path = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        guard proc_pidpath(getpid(), &path, UInt32(path.count)) == 0 else { return false }
        var code: SecCode?
        let status = SecCodeCopySelf([], &code)
        // Security reports Unix errors as 100000 + errno. Other identity failures
        // must not turn an ordinary connection failure into a restart.
        let missingFile = OSStatus(100_000 + ENOENT)
        if status == missingFile { return true }
        guard status == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], nil) == missingFile
    }

    private static func validatedHash(at url: URL, requirement text: String) -> Data? {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
            let code,
            SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
            let requirement,
            SecStaticCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode),
                requirement
            ) == errSecSuccess
        else { return nil }
        return codeHash(code)
    }

    private static func codeHash(_ code: SecStaticCode) -> Data? {
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let information = information as? [String: Any]
        else { return nil }
        return information[kSecCodeInfoUnique as String] as? Data
    }

    static func validates(_ application: NSRunningApplication, replacement: Replacement) -> Bool {
        guard application.processIdentifier != getpid(), !application.isTerminated,
            application.bundleURL?.standardizedFileURL == replacement.app.standardizedFileURL,
            application.bundleIdentifier == "org.hardpause.app"
        else { return false }
        var code: SecCode?
        var staticCode: SecStaticCode?
        var requirement: SecRequirement?
        let attributes = [kSecGuestAttributePid as String: application.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
            let code,
            SecRequirementCreateWithString(BrowserWorkerIdentity.appRequirement as CFString, [], &requirement)
                == errSecSuccess,
            let requirement,
            SecCodeCheckValidity(code, [], requirement) == errSecSuccess,
            SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
            let staticCode, codeHash(staticCode) == replacement.codeHash
        else { return false }
        return true
    }

    /// The invalid GUI cannot authenticate to XPC. The validated installed worker can.
    @MainActor
    static func browserCoverage(for replacement: Replacement) async -> BrowserWorkerReadiness? {
        for name in BrowserWorkerClient.installedMachServices().prefix(4) {
            guard !Task.isCancelled, self.replacement() == replacement else { return nil }
            let process = Process()
            let output = Pipe()
            process.executableURL = replacement.worker
            process.arguments = ["--probe-existing", name]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { continue }
            let reader = Task.detached(priority: .utility) { () -> Data? in
                defer { try? output.fileHandleForReading.close() }
                var data = Data()
                do {
                    while let chunk = try output.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
                        guard data.count + chunk.count <= 16_384 else { return nil }
                        data.append(chunk)
                    }
                    return data
                } catch { return nil }
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while process.isRunning, !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            let expired = process.isRunning || Task.isCancelled
            if process.isRunning {
                // --probe-existing owns no worker or service. Reap only this read-only child.
                _ = kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            guard let data = await reader.value, !expired, process.terminationStatus == 0,
                let report = try? JSONDecoder().decode(BrowserWorkerReadiness.self, from: data),
                report.isFresh(), report.readyForHandoff,
                report.pausePageURL.map(BrowserWorkerIdentity.isLocalPausePage) == true
            else { continue }
            return report
        }
        return nil
    }

    @MainActor
    static func launch(_ replacement: Replacement) async throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = [relaunchArgument]
        return try await NSWorkspace.shared.openApplication(at: replacement.app, configuration: configuration)
    }
}
