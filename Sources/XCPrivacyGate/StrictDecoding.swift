import Foundation

struct UnknownKeyError: Error {
    let codingPath: [any CodingKey]
}

enum StrictJSON {
    static func decode<Value: Decodable>(_ type: Value.Type, contentsOf file: URL, document: String) throws -> Value {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw ToolError(message: "cannot read \(document): \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ToolError(message: message(error, document: document))
        }
    }

    static func message(_ error: any Error, document: String, below base: [any CodingKey] = []) -> String {
        switch error {
        case let error as ToolError:
            error.message
        case let error as UnknownKeyError:
            "unknown key \(quoted(error.codingPath, below: base))"
        case let error as DecodingError:
            message(error, document: document, below: base)
        default:
            "\(document) is invalid: \(error)"
        }
    }

    private static func message(_ error: DecodingError, document: String, below base: [any CodingKey]) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            "missing key \(quoted(context.codingPath + [key], below: base))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            context.codingPath.count > base.count
                ? "wrong type for key \(quoted(context.codingPath, below: base))"
                : "\(document) must be a JSON object"
        case .dataCorrupted:
            "not valid JSON"
        @unknown default:
            "\(document) is invalid: \(error)"
        }
    }

    private static func quoted(_ path: [any CodingKey], below base: [any CodingKey]) -> String {
        "\"\(path.dropFirst(base.count).map(\.stringValue).joined(separator: "."))\""
    }
}

struct AnyKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        return nil
    }
}

extension Decoder {
    func rejectUnknownKeys<Keys: CodingKey & CaseIterable>(of keys: Keys.Type) throws {
        let known = Set(Keys.allCases.map(\.stringValue))
        let container = try container(keyedBy: AnyKey.self)
        let unknown = container.allKeys.map(\.stringValue).filter { !known.contains($0) }.sorted()
        if let first = unknown.first {
            throw UnknownKeyError(codingPath: codingPath + [AnyKey(first)])
        }
    }
}
