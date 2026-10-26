import Foundation

package enum PlistValue: Sendable {
    case dictionary([String: PlistValue])
    case array([PlistValue])
    case string(String)
    case bool(Bool)
    case integer(Int)
    case real(Double)
    case date(String)
    case data(String)
}

package enum PlistReadError: Error {
    case duplicateKey(String)
    case invalid(String)
}

package enum PlistReader {
    private static let xmlWhitespace: Set<UInt8> = [0x20, 0x09, 0x0D, 0x0A]

    package static func read(_ data: Data) throws(PlistReadError) -> PlistValue {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw .invalid((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription)
        }
        if !data.starts(with: Data("bplist".utf8)) {
            try XMLKeyCheck(data.drop { xmlWhitespace.contains($0) }).run()
        }
        return try value(of: object)
    }

    private static func value(of object: Any) throws(PlistReadError) -> PlistValue {
        switch object {
        case let string as String:
            return .string(string)
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return .bool(number.boolValue)
        case let number as NSNumber:
            return CFNumberIsFloatType(number) ? .real(number.doubleValue) : .integer(number.intValue)
        case let date as Date:
            return .date(date.formatted(.iso8601))
        case let data as Data:
            return .data(data.base64EncodedString())
        case let array as [Any]:
            return .array(try array.map(value(of:)))
        case let dictionary as [String: Any]:
            var values: [String: PlistValue] = [:]
            for (key, item) in dictionary {
                values[key] = try value(of: item)
            }
            return .dictionary(values)
        default:
            throw .invalid("unsupported value of type \(type(of: object))")
        }
    }
}

private final class XMLKeyCheck: NSObject, XMLParserDelegate {
    private let parser: XMLParser
    private var dictionaryKeys: [Set<String>?] = []
    private var key: String?
    private var failure: PlistReadError?

    init(_ data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func run() throws(PlistReadError) {
        parser.parse()
        if let failure {
            throw failure
        }
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "dict":
            dictionaryKeys.append([])
        case "array":
            dictionaryKeys.append(nil)
        case "key":
            key = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "dict", "array":
            _ = dictionaryKeys.popLast()
        case "key":
            closeKey()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        key? += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        key? += String(bytes: CDATABlock, encoding: .utf8) ?? ""
    }

    private func closeKey() {
        let name = key ?? ""
        key = nil
        guard let top = dictionaryKeys.indices.last, dictionaryKeys[top] != nil else {
            return fail(.invalid("unexpected key at line \(parser.lineNumber)"))
        }
        if dictionaryKeys[top]?.insert(name).inserted == false {
            fail(.duplicateKey(name))
        }
    }

    private func fail(_ error: PlistReadError) {
        guard failure == nil else { return }
        failure = error
        parser.abortParsing()
    }
}

extension PlistValue {
    static func list(_ strings: [String]) -> PlistValue {
        .array(strings.map(PlistValue.string))
    }

    var pythonRepr: String {
        switch self {
        case .dictionary(let entries):
            "{" + entries.sorted { $0.key.pythonPrecedes($1.key) }.map { "\($0.key.pythonRepr): \($0.value.pythonRepr)" }.joined(separator: ", ") + "}"
        case .array(let items):
            "[" + items.map(\.pythonRepr).joined(separator: ", ") + "]"
        case .string(let text):
            text.pythonRepr
        case .bool(let flag):
            flag ? "True" : "False"
        case .integer(let number):
            String(number)
        case .real(let number):
            number.description
        case .date(let text), .data(let text):
            text
        }
    }

    var pythonStr: String {
        guard case .string(let text) = self else { return pythonRepr }
        return text
    }

    var plistTypeName: String {
        switch self {
        case .dictionary: "dictionary"
        case .array: "array"
        case .string: "string"
        case .bool: "boolean"
        case .integer: "integer"
        case .real: "real"
        case .date: "date"
        case .data: "data"
        }
    }
}

extension String {
    func pythonPrecedes(_ other: String) -> Bool {
        unicodeScalars.lexicographicallyPrecedes(other.unicodeScalars)
    }

    var pythonRepr: String {
        let quote: Unicode.Scalar = unicodeScalars.contains("'") && !unicodeScalars.contains("\"") ? "\"" : "'"
        let body = unicodeScalars.map { Self.escaped($0, quote: quote) }.joined()
        return "\(quote)\(body)\(quote)"
    }

    private static func escaped(_ scalar: Unicode.Scalar, quote: Unicode.Scalar) -> String {
        switch scalar {
        case "\\", quote:
            "\\\(scalar)"
        case "\t":
            "\\t"
        case "\n":
            "\\n"
        case "\r":
            "\\r"
        case _ where isPrintable(scalar):
            String(scalar)
        default:
            hexEscaped(scalar.value)
        }
    }

    private static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.isASCII {
            return scalar.value >= 0x20 && scalar.value != 0x7F
        }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return false
        default:
            return true
        }
    }

    private static func hexEscaped(_ value: UInt32) -> String {
        let (prefix, width) = value <= 0xFF ? ("\\x", 2) : value <= 0xFFFF ? ("\\u", 4) : ("\\U", 8)
        let digits = String(value, radix: 16)
        return prefix + String(repeating: "0", count: width - digits.count) + digits
    }
}

extension Sequence<String> {
    func pythonSorted() -> [String] {
        sorted { $0.pythonPrecedes($1) }
    }
}
