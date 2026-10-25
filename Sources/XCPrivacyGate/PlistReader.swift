import Foundation

package enum PlistValue: Sendable {
    case dictionary([(key: String, value: PlistValue)])
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
    package static func read(_ data: Data) throws(PlistReadError) -> PlistValue? {
        guard data.starts(with: Data("bplist".utf8)) else {
            return try XMLPlistBuilder(data).build()
        }
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, format: nil)
        } catch {
            throw .invalid(error.localizedDescription)
        }
        return try value(of: object)
    }

    private static func value(of object: Any) throws(PlistReadError) -> PlistValue {
        switch object {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            return value(of: number)
        case let date as Date:
            return .date(date.formatted(.iso8601))
        case let data as Data:
            return .data(data.base64EncodedString())
        case let array as [Any]:
            return .array(try array.map(value(of:)))
        case let dictionary as [String: Any]:
            return .dictionary(try dictionary.sorted { $0.key.pythonPrecedes($1.key) }.map { entry throws(PlistReadError) in
                (key: entry.key, value: try value(of: entry.value))
            })
        default:
            throw .invalid("unsupported value of type \(type(of: object))")
        }
    }

    private static func value(of number: NSNumber) -> PlistValue {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return .bool(number.boolValue)
        }
        return CFNumberIsFloatType(number) ? .real(number.doubleValue) : .integer(number.intValue)
    }
}

private final class XMLPlistBuilder: NSObject, XMLParserDelegate {
    private struct Frame {
        let isDictionary: Bool
        var keys: [String] = []
        var values: [PlistValue] = []

        var value: PlistValue {
            isDictionary ? .dictionary(zip(keys, values).map { (key: $0, value: $1) }) : .array(values)
        }
    }

    private let parser: XMLParser
    private var stack: [Frame] = []
    private var currentKey: String?
    private var root: PlistValue?
    private var text = ""
    private var failure: PlistReadError?

    init(_ data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func build() throws(PlistReadError) -> PlistValue? {
        let parsed = parser.parse()
        if let failure {
            throw failure
        }
        guard parsed else {
            throw .invalid(parser.parserError?.localizedDescription ?? "the XML parser stopped")
        }
        return root
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        text = ""
        switch elementName {
        case "dict":
            perform { () throws(PlistReadError) in try open(Frame(isDictionary: true)) }
        case "array":
            perform { () throws(PlistReadError) in try open(Frame(isDictionary: false)) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        perform { () throws(PlistReadError) in try close(elementName) }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        perform { () throws(PlistReadError) in
            guard let block = String(bytes: CDATABlock, encoding: .utf8) else { throw unexpected("CDATA encoding") }
            text += block
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        rejectEntityDeclaration()
    }

    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) {
        rejectEntityDeclaration()
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
        guard failure == nil else { return }
        let message = (parseError as NSError).userInfo["NSXMLParserErrorMessage"] as? String ?? parseError.localizedDescription
        failure = .invalid("\(message.trimmingCharacters(in: .whitespacesAndNewlines)): line \(parser.lineNumber), column \(parser.columnNumber)")
    }

    private func perform(_ step: () throws(PlistReadError) -> Void) {
        do {
            try step()
        } catch {
            failure = error
            parser.abortParsing()
        }
    }

    private func rejectEntityDeclaration() {
        perform { () throws(PlistReadError) in throw .invalid("XML entity declarations are not supported in plist files") }
    }

    private func open(_ frame: Frame) throws(PlistReadError) {
        try add(frame.value)
        stack.append(frame)
    }

    private func close(_ elementName: String) throws(PlistReadError) {
        switch elementName {
        case "dict":
            try closeDictionary()
        case "array":
            try closeContainer()
        case "key":
            try closeKey()
        case "true", "false":
            try add(.bool(elementName == "true"))
        case "integer":
            try add(.integer(Self.integer(takeText())))
        case "real":
            try add(.real(Self.real(takeText())))
        case "string":
            try add(.string(takeText()))
        case "date":
            try add(.date(takeText()))
        case "data":
            try add(.data(takeText()))
        default:
            break
        }
    }

    private func add(_ value: PlistValue) throws(PlistReadError) {
        guard let top = stack.indices.last else {
            guard currentKey == nil else { throw unexpected("element") }
            root = value
            return
        }
        guard let key = currentKey else {
            guard !stack[top].isDictionary else { throw unexpected("element") }
            stack[top].values.append(value)
            return
        }
        guard stack[top].isDictionary else { throw unexpected("element") }
        guard !stack[top].keys.contains(key) else { throw .duplicateKey(key) }
        stack[top].keys.append(key)
        stack[top].values.append(value)
        currentKey = nil
    }

    private func closeDictionary() throws(PlistReadError) {
        if let key = currentKey, !key.isEmpty {
            throw .invalid("missing value for key '\(key)' at line \(parser.lineNumber)")
        }
        try closeContainer()
    }

    private func closeContainer() throws(PlistReadError) {
        guard let frame = stack.popLast() else { throw unexpected("element") }
        guard let top = stack.indices.last, let slot = stack[top].values.indices.last else {
            root = frame.value
            return
        }
        stack[top].values[slot] = frame.value
    }

    private func closeKey() throws(PlistReadError) {
        guard currentKey?.isEmpty ?? true, stack.last?.isDictionary == true else { throw unexpected("key") }
        currentKey = takeText()
    }

    private func takeText() -> String {
        defer { text = "" }
        return text
    }

    private func unexpected(_ what: String) -> PlistReadError {
        .invalid("unexpected \(what) at line \(parser.lineNumber)")
    }

    private static func integer(_ raw: String) throws(PlistReadError) -> Int {
        let isHex = raw.hasPrefix("0x") || raw.hasPrefix("0X")
        let digits = (isHex ? String(raw.dropFirst(2)) : raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(digits, radix: isHex ? 16 : 10) else {
            throw .invalid("invalid literal for int() with base \(isHex ? 16 : 10): \(raw.pythonRepr)")
        }
        return value
    }

    private static func real(_ raw: String) throws(PlistReadError) -> Double {
        guard let value = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .invalid("could not convert string to float: \(raw.pythonRepr)")
        }
        return value
    }
}

extension PlistValue {
    static func list(_ strings: [String]) -> PlistValue {
        .array(strings.map(PlistValue.string))
    }

    var pythonRepr: String {
        switch self {
        case .dictionary(let entries):
            "{" + entries.map { "\($0.key.pythonRepr): \($0.value.pythonRepr)" }.joined(separator: ", ") + "}"
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

    var pythonTypeName: String {
        switch self {
        case .dictionary: "dict"
        case .array: "list"
        case .string: "str"
        case .bool: "bool"
        case .integer: "int"
        case .real: "float"
        case .date: "datetime"
        case .data: "bytes"
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
