import Foundation

enum ProtectedServiceContract {
    static let machServiceName = "org.hardpause.service"
    static let serviceVersion = "7"
    static let safeUpdateSourceVersions: Set<String> = ["4", "5", "6"]
    static let maximumPayloadBytes = 1_048_576
    static let supportDirectory = "/Library/Application Support/HardPause"
    static let enrollmentPath = "\(supportDirectory)/enrollment-v1.json"
    static let statePath = "\(supportDirectory)/state-v2.json"
    static let appleLockdownStatePath = "\(supportDirectory)/apple-lockdown-state-v1.json"
    static let backupDirectory = "\(supportDirectory)/backups"

    static func supportsSafeUpdate(from installedVersion: String) -> Bool {
        installedVersion == serviceVersion || safeUpdateSourceVersions.contains(installedVersion)
    }
}

@objc protocol ProtectedServiceXPC {
    func list(withReply reply: @escaping (NSData) -> Void)
    func create(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
    func update(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
    func delete(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
    func activate(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
    func requestBreak(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
    func cancelBreak(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
    func requestEnd(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
    func prepareUpdate(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
    func cancelUpdate(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
    func appleLockdownStatus(withReply reply: @escaping (NSData) -> Void)
    func beginAppleLockdownSetup(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
    func resumeAppleLockdownSetup(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
    func completeAppleLockdownSetup(_ request: NSData, withReply reply: @escaping (NSData) -> Void)
    func confirmAppleLockdownSetupNotApplied(
        _ request: NSData,
        withReply reply: @escaping (NSData) -> Void
    )
    func requestAppleLockdownEnd(withReply reply: @escaping (NSData) -> Void)
    func beginAppleLockdownRelease(withReply reply: @escaping (NSData) -> Void)
    func completeAppleLockdownRelease(
        _ request: NSData,
        withReply reply: @escaping (NSData) -> Void
    )
}

struct ProtectedCreateRequest: Codable, Equatable, Sendable {
    let draft: ProtectedBlockDraft
}

struct ProtectedUpdateRequest: Codable, Equatable, Sendable {
    let id: UUID
    let expectedRevision: Int
    let draft: ProtectedBlockDraft
}

struct ProtectedRevisionRequest: Codable, Equatable, Sendable {
    let id: UUID
    let expectedRevision: Int
}

struct ProtectedBlockRequest: Codable, Equatable, Sendable {
    let id: UUID
}

struct ProtectedServiceErrorPayload: Codable, Equatable, Sendable {
    let code: String
    let message: String
}

struct ProtectedServiceReply: Codable, Equatable, Sendable {
    let snapshot: ProtectedServiceSnapshot?
    let error: ProtectedServiceErrorPayload?

    static func success(_ snapshot: ProtectedServiceSnapshot) -> ProtectedServiceReply {
        ProtectedServiceReply(snapshot: snapshot, error: nil)
    }

    static func failure(code: String, message: String) -> ProtectedServiceReply {
        ProtectedServiceReply(
            snapshot: nil,
            error: ProtectedServiceErrorPayload(code: code, message: message)
        )
    }
}

struct ProtectedServiceEnrollment: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let enrolledUID: UInt32
    let approvedClientRequirements: [String]

    init(
        enrolledUID: UInt32,
        approvedClientRequirements: [String]
    ) {
        schemaVersion = 1
        self.enrolledUID = enrolledUID
        self.approvedClientRequirements = approvedClientRequirements
    }

    func validate() throws {
        guard schemaVersion == 1 else {
            throw ProtectedServiceCodecError.invalid("The enrollment format is not supported.")
        }
        guard enrolledUID > 0 else {
            throw ProtectedServiceCodecError.invalid("The enrolled user must not be root.")
        }
        guard (1...8).contains(approvedClientRequirements.count),
            Set(approvedClientRequirements).count == approvedClientRequirements.count,
            approvedClientRequirements.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.count <= ProtectedBlockLimits.maximumRequirementLength
            })
        else {
            throw ProtectedServiceCodecError.invalid("The approved client requirements are invalid.")
        }
    }
}

enum ProtectedServiceCodec {
    static func encode<T: Encodable>(_ value: T) throws -> NSData {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= ProtectedServiceContract.maximumPayloadBytes else {
            throw ProtectedServiceCodecError.payloadTooLarge
        }
        return data as NSData
    }

    static func decode<T: Decodable>(_ type: T.Type, from payload: NSData) throws -> T {
        guard payload.length <= ProtectedServiceContract.maximumPayloadBytes else {
            throw ProtectedServiceCodecError.payloadTooLarge
        }
        return try JSONDecoder().decode(type, from: payload as Data)
    }
}

enum ProtectedServiceCodecError: LocalizedError, Equatable {
    case payloadTooLarge
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge: return "The service request is too large."
        case .invalid(let message): return message
        }
    }
}
