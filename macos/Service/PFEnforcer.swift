import Darwin
import Foundation

protocol PFTokenStoring: AnyObject {
    func load() throws -> PFEnableToken?
    func save(_ token: PFEnableToken?) throws
}

struct PFEnableToken: Codable, Equatable {
    let value: String
    let bootIdentifier: String
}

final class FilePFTokenStore: PFTokenStoring {
    private let url: URL
    private let requireRootOwnership: Bool

    init(
        url: URL = URL(
            fileURLWithPath: ProtectedServiceContract.supportDirectory
        ).appendingPathComponent("pf-enable-token"),
        requireRootOwnership: Bool = true
    ) {
        self.url = url
        self.requireRootOwnership = requireRootOwnership
    }

    func load() throws -> PFEnableToken? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size > 0,
            info.st_size <= 512
        else {
            throw ServiceRuntimeError.enforcementFailed("the PF token file is invalid")
        }
        if requireRootOwnership, info.st_uid != 0 || (info.st_mode & 0o077) != 0 {
            throw ServiceRuntimeError.enforcementFailed("the PF token file must be root-only")
        }
        let token: PFEnableToken
        do {
            token = try JSONDecoder().decode(PFEnableToken.self, from: Data(contentsOf: url))
        } catch {
            throw ServiceRuntimeError.enforcementFailed("the PF token file cannot be decoded")
        }
        guard Self.isValid(token.value), Self.isValidBootIdentifier(token.bootIdentifier) else {
            throw ServiceRuntimeError.enforcementFailed("the PF token value is invalid")
        }
        return token
    }

    func save(_ token: PFEnableToken?) throws {
        if let token {
            guard Self.isValid(token.value), Self.isValidBootIdentifier(token.bootIdentifier) else {
                throw ServiceRuntimeError.enforcementFailed("the PF token value is invalid")
            }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let temporary = directory.appendingPathComponent(".pf-token-\(UUID().uuidString)")
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(token).write(to: temporary, options: .withoutOverwriting)
            guard chmod(temporary.path, 0o600) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw ServiceRuntimeError.enforcementFailed(String(cString: strerror(errno)))
            }
            if requireRootOwnership, chown(temporary.path, 0, 0) != 0 {
                try? FileManager.default.removeItem(at: temporary)
                throw ServiceRuntimeError.enforcementFailed(String(cString: strerror(errno)))
            }
            guard rename(temporary.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: temporary)
                throw ServiceRuntimeError.enforcementFailed(String(cString: strerror(errno)))
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func isValid(_ token: String) -> Bool {
        !token.isEmpty && token.count <= 32 && token.allSatisfy(\.isNumber)
    }

    private static func isValidBootIdentifier(_ identifier: String) -> Bool {
        !identifier.isEmpty && identifier.utf8.count <= 256
    }
}

final class PFEnforcer: PFRuleEnforcing {
    static let anchor = "com.apple/hard-pause"
    static let standbyAnchor = "com.apple/hard-pause-standby"

    private let runner: CommandRunning
    private let tokenStore: PFTokenStoring
    private let executable: String
    private let anchor: String
    private let bootIdentifier: @Sendable () -> String?
    private var lastAppliedAddresses: Set<String>?

    init(
        runner: CommandRunning = ProcessCommandRunner(),
        tokenStore: PFTokenStoring = FilePFTokenStore(),
        executable: String = "/sbin/pfctl",
        anchor: String = PFEnforcer.anchor,
        bootIdentifier: @escaping @Sendable () -> String? = { SystemClock.read().bootIdentifier }
    ) {
        self.runner = runner
        self.tokenStore = tokenStore
        self.executable = executable
        self.anchor = anchor
        self.bootIdentifier = bootIdentifier
    }

    func apply(addresses: [String], blockIDs: [UUID]) throws -> [ProtectionIssue] {
        let addresses = Array(Set(addresses)).sorted()
        guard addresses.allSatisfy(DomainRule.isLiteralIPAddress) else {
            throw ServiceRuntimeError.enforcementFailed("the PF rules contain a non-literal address")
        }

        if addresses.isEmpty {
            try requireSuccess(["-a", anchor, "-F", "rules"], operation: "clear owned PF rules")
            guard let currentBootIdentifier = bootIdentifier() else {
                return [
                    ProtectionIssue(
                        code: "ip_filter_unavailable",
                        message:
                            "Owned PF rules were cleared, but the enable token was retained because the current boot cannot be identified safely.",
                        blockIDs: blockIDs
                    )
                ]
            }
            let storedToken = try tokenStore.load()
            if let storedToken, storedToken.bootIdentifier == currentBootIdentifier {
                try requireSuccess(
                    ["-X", storedToken.value],
                    operation: "release the owned PF token"
                )
                try tokenStore.save(nil)
            } else if storedToken != nil {
                try tokenStore.save(nil)
            }
            lastAppliedAddresses = []
            return []
        }

        guard let currentBootIdentifier = bootIdentifier() else {
            return [
                ProtectionIssue(
                    code: "ip_filter_unavailable",
                    message: "Literal IP blocking is unavailable because the current boot cannot be identified safely.",
                    blockIDs: blockIDs
                )
            ]
        }

        let storedToken = try tokenStore.load()
        let currentToken: PFEnableToken?
        if let storedToken, storedToken.bootIdentifier == currentBootIdentifier {
            currentToken = storedToken
        } else {
            if storedToken != nil { try tokenStore.save(nil) }
            currentToken = nil
        }

        let activeRules = try requireSuccess(["-sr"], operation: "inspect the active PF rules")
        guard hasAppleDispatcher(activeRules.standardOutput) else {
            return [
                ProtectionIssue(
                    code: "ip_filter_unavailable",
                    message:
                        "Literal IP blocking is unavailable because the active PF rules do not dispatch com.apple child anchors.",
                    blockIDs: blockIDs
                )
            ]
        }

        var token = currentToken
        var acquiredToken: PFEnableToken?
        if token == nil {
            let enabled = try requireSuccess(["-E"], operation: "acquire a PF enable token")
            let acquired = PFEnableToken(
                value: try parseToken(enabled.standardOutput + "\n" + enabled.standardError),
                bootIdentifier: currentBootIdentifier
            )
            do {
                try tokenStore.save(acquired)
            } catch {
                _ = try? runner.run(
                    executable: executable,
                    arguments: ["-X", acquired.value],
                    standardInput: nil
                )
                throw error
            }
            token = acquired
            acquiredToken = acquired
        }

        let rules = addresses.map { "block drop quick to \($0)" }.joined(separator: "\n") + "\n"
        do {
            _ = try requireSuccess(
                ["-a", anchor, "-f", "-"],
                standardInput: Data(rules.utf8),
                operation: "load owned PF rules"
            )
            let newlyBlocked = Set(addresses).subtracting(lastAppliedAddresses ?? [])
            for address in newlyBlocked.sorted() {
                let sourceWildcard = address.contains(":") ? "::/0" : "0.0.0.0/0"
                try requireSuccess(
                    ["-k", sourceWildcard, "-k", address],
                    operation: "remove existing connections to \(address)"
                )
            }
        } catch {
            if let acquiredToken {
                _ = try? runner.run(
                    executable: executable,
                    arguments: ["-a", anchor, "-F", "rules"],
                    standardInput: nil
                )
                _ = try? runner.run(
                    executable: executable,
                    arguments: ["-X", acquiredToken.value],
                    standardInput: nil
                )
                try? tokenStore.save(nil)
            }
            throw error
        }
        _ = token
        lastAppliedAddresses = Set(addresses)
        return []
    }

    func hasAppleDispatcher(_ activeRules: String) -> Bool {
        activeRules.split(separator: "\n").contains { line in
            let compact = line.trimmingCharacters(in: .whitespaces)
            return compact.hasPrefix("anchor \"com.apple/*\"")
                || compact.contains(" anchor \"com.apple/*\"")
        }
    }

    private func parseToken(_ output: String) throws -> String {
        let pattern = #"(?m)^Token\s*:\s*([0-9]{1,32})\s*$"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(output.startIndex..., in: output)
        guard let match = expression.firstMatch(in: output, range: range),
            let tokenRange = Range(match.range(at: 1), in: output)
        else {
            throw ServiceRuntimeError.enforcementFailed("pfctl did not return an enable token")
        }
        return String(output[tokenRange])
    }

    @discardableResult
    private func requireSuccess(
        _ arguments: [String],
        standardInput: Data? = nil,
        operation: String
    ) throws -> CommandResult {
        let result = try runner.run(
            executable: executable,
            arguments: arguments,
            standardInput: standardInput
        )
        guard result.status == 0 else {
            let detail = result.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ServiceRuntimeError.enforcementFailed(
                "could not \(operation)\(detail.isEmpty ? "" : ": \(detail)")"
            )
        }
        return result
    }
}
