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

package enum PlistPathComponent: Hashable, Sendable {
    case key(String)
    case index(Int)
}

package struct PlistDocument: Sendable {
    package let root: PlistValue
    package let lines: [[PlistPathComponent]: Int]
}

package enum PlistReadError: Error {
    case duplicateKey(String, line: Int)
    case invalid(String)
}

package enum PlistReader {
    private static let xmlWhitespace: Set<UInt8> = [0x20, 0x09, 0x0D, 0x0A]

    package static func read(_ data: Data) throws(PlistReadError) -> PlistDocument {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw .invalid((error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? error.localizedDescription)
        }
        var lines: [[PlistPathComponent]: Int] = [:]
        if !data.starts(with: Data("bplist".utf8)) {
            let leading = data.prefix { xmlWhitespace.contains($0) }
            lines = try XMLStructure(data.dropFirst(leading.count), firstLine: 1 + leading.count(where: { $0 == 0x0A })).lines()
        }
        return PlistDocument(root: try value(of: object), lines: lines)
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

private final class XMLStructure: NSObject, XMLParserDelegate {
    private struct Container {
        let path: [PlistPathComponent]
        var keys: Set<String>?
        var count = 0
    }

    private let parser: XMLParser
    private let firstLine: Int
    private var containers: [Container] = []
    private var key: (name: String, line: Int)?
    private var valueKey: String?
    private var found: [[PlistPathComponent]: Int] = [:]
    private var failure: PlistReadError?

    init(_ data: Data, firstLine: Int) {
        parser = XMLParser(data: data)
        self.firstLine = firstLine
        super.init()
        parser.delegate = self
    }

    func lines() throws(PlistReadError) -> [[PlistPathComponent]: Int] {
        parser.parse()
        if let failure {
            throw failure
        }
        return found
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "plist":
            break
        case "key":
            key = ("", line)
        default:
            let path = valuePath()
            if elementName == "dict" || elementName == "array" {
                containers.append(Container(path: path, keys: elementName == "dict" ? [] : nil))
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "dict", "array":
            _ = containers.popLast()
        case "key":
            closeKey()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        key?.name += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        key?.name += String(bytes: CDATABlock, encoding: .utf8) ?? ""
    }

    private var line: Int {
        firstLine + parser.lineNumber - 1
    }

    private func valuePath() -> [PlistPathComponent] {
        guard let top = containers.indices.last else {
            return []
        }
        if containers[top].keys == nil {
            let path = containers[top].path + [.index(containers[top].count)]
            containers[top].count += 1
            found[path] = line
            return path
        }
        defer { valueKey = nil }
        return containers[top].path + [.key(valueKey ?? "")]
    }

    private func closeKey() {
        let (name, keyLine) = key ?? ("", line)
        key = nil
        guard let top = containers.indices.last, containers[top].keys != nil else {
            return fail(.invalid("unexpected key at line \(keyLine)"))
        }
        if containers[top].keys?.insert(name).inserted == false {
            return fail(.duplicateKey(name, line: keyLine))
        }
        found[containers[top].path + [.key(name)]] = keyLine
        valueKey = name
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

    var literal: String {
        switch self {
        case .dictionary(let entries):
            "{" + entries.sorted { $0.key.pythonPrecedes($1.key) }.map { "\($0.key.quoted): \($0.value.literal)" }.joined(separator: ", ") + "}"
        case .array(let items):
            "[" + items.map(\.literal).joined(separator: ", ") + "]"
        case .string(let text):
            text.quoted
        case .bool(let flag):
            String(flag)
        case .integer(let number):
            String(number)
        case .real(let number):
            number.description
        case .date(let text), .data(let text):
            text
        }
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
    var quoted: String {
        "\"" + unicodeScalars.map(\.quoted).joined() + "\""
    }

    var isPlain: Bool {
        unicodeScalars.allSatisfy { $0.isVisible && !$0.properties.isWhitespace }
    }

    func pythonPrecedes(_ other: String) -> Bool {
        unicodeScalars.lexicographicallyPrecedes(other.unicodeScalars)
    }
}

private extension Unicode.Scalar {
    var quoted: String {
        switch self {
        case "\"", "\\":
            "\\\(self)"
        case "\n":
            "\\n"
        case "\t":
            "\\t"
        case "\r":
            "\\r"
        case _ where isVisible:
            String(self)
        default:
            "\\u{\(String(value, radix: 16, uppercase: true))}"
        }
    }

    var isVisible: Bool {
        if isASCII {
            return value >= 0x20 && value != 0x7F
        }
        switch properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return false
        default:
            return true
        }
    }
}

extension Sequence<String> {
    func pythonSorted() -> [String] {
        sorted { $0.pythonPrecedes($1) }
    }
}
