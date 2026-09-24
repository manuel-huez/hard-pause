import Foundation

enum RustCoreBridge {
    enum Failure: Error {
        case unavailable
        case rejected(String)
    }

    private struct Request<Arguments: Encodable>: Encodable {
        let version = 1
        let op: String
        let args: Arguments
    }

    private struct Response<Result: Decodable>: Decodable {
        struct CoreError: Decodable { let code: String }
        let ok: Bool
        let result: Result?
        let error: CoreError?
    }

    static func call<Arguments: Encodable, Result: Decodable>(
        _ operation: String,
        _ arguments: Arguments,
        as resultType: Result.Type = Result.self
    ) throws -> Result {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let request = try encoder.encode(Request(op: operation, args: arguments))
        var output = HpCoreBuffer(ptr: nil, len: 0)
        let status = request.withUnsafeBytes { bytes in
            hp_core_call(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &output)
        }
        guard status == 0, let pointer = output.ptr else {
            throw Failure.unavailable
        }
        defer { hp_core_free(output) }
        let response = try JSONDecoder.rustCore.decode(
            Response<Result>.self,
            from: Data(bytes: pointer, count: output.len)
        )
        if response.ok, let result = response.result { return result }
        if let code = response.error?.code { throw Failure.rejected(code) }
        throw Failure.unavailable
    }
}

extension JSONDecoder {
    fileprivate static var rustCore: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }
}
