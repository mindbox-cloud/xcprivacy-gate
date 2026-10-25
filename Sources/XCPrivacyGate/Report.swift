import Foundation

public struct Violation: Equatable, Sendable {
    public let code: String
    public let module: String?
    public let message: String
    public let file: String?
    public let line: Int?

    public init(code: String, module: String?, message: String, file: String? = nil, line: Int? = nil) {
        self.code = code
        self.module = module
        self.message = message
        self.file = file
        self.line = line
    }
}

public struct ToolError: Error, CustomStringConvertible {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

public enum Report {
    public static func annotation(_ violation: Violation, root: URL) -> String {
        var properties: [String] = []
        if let file = violation.file, !file.isEmpty {
            properties.append("file=\(escapeProperty(repositoryRelative(file, root: root)))")
            if let line = violation.line {
                properties.append("line=\(line)")
            }
        }
        properties.append("title=\(escapeProperty(violation.code))")
        return "::error \(properties.joined(separator: ","))::\(escapeData(violation.message))"
    }

    public static func summary(title: String, violations: [Violation]) -> String {
        let noun = violations.count == 1 ? "violation" : "violations"
        let header = "Privacy manifest gate, \(title): \(violations.count) \(noun)"
        return ([header] + violations.map { "\($0.code) \($0.message)" }).joined(separator: "\n")
    }

    public static func exitCode(violations: [Violation]) -> Int32 {
        violations.isEmpty ? 0 : 1
    }

    private static func repositoryRelative(_ path: String, root: URL) -> String {
        guard path.hasPrefix("/") else { return path }
        let rootComponents = root.standardizedFileURL.pathComponents
        let pathComponents = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard pathComponents.count > rootComponents.count, pathComponents.starts(with: rootComponents) else { return path }
        return pathComponents.dropFirst(rootComponents.count).joined(separator: "/")
    }

    private static let dataEscapes: [Unicode.Scalar: String] = ["%": "%25", "\r": "%0D", "\n": "%0A"]
    private static let propertyEscapes = dataEscapes.merging([":": "%3A", ",": "%2C"]) { current, _ in current }

    private static func escapeData(_ value: String) -> String {
        escape(value, using: dataEscapes)
    }

    private static func escapeProperty(_ value: String) -> String {
        escape(value, using: propertyEscapes)
    }

    private static func escape(_ value: String, using escapes: [Unicode.Scalar: String]) -> String {
        value.unicodeScalars.reduce(into: "") { result, scalar in
            result += escapes[scalar] ?? String(scalar)
        }
    }
}
