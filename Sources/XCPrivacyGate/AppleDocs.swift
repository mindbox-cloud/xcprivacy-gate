import Foundation

public enum AppleDocs {
    public typealias RequiredReasonCategory = (reasons: [String: String], apis: [(api: String, docc: String?)])

    private static let categoryPrefix = "NSPrivacyAccessedAPICategory"

    public static func document(_ data: Data, from source: String) throws -> [String: Any] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            throw ToolError(message: "\(source) is not JSON: \(preview(data))")
        }
        guard let document = object as? [String: Any] else {
            throw ToolError(message: "\(source) is not a DocC JSON object")
        }
        return document
    }

    public static func requiredReasons(_ doc: [String: Any]) throws -> [String: RequiredReasonCategory] {
        let page = DocCNode(doc)
        let references = try page.node("references")
        var result: [String: RequiredReasonCategory] = [:]
        for value in try possibleValues(page) {
            let category = try value.string("name") ?? ""
            guard category.hasPrefix(categoryPrefix) else {
                throw ToolError(message: "unexpected category name \(quoted(category))")
            }
            let apiList = try singleBlock(value, kind: "unorderedList", category: category)
            let reasonList = try singleBlock(value, kind: "termList", category: category)
            var reasons: [String: String] = [:]
            for item in try reasonList.nodes("items") {
                let code = try reasonCode(item, category: category)
                reasons[code] = try definitionText(item, references: references)
            }
            let apis = try apiList.nodes("items").map { try apiEntry($0, references: references, category: category) }
            guard !reasons.isEmpty, !apis.isEmpty else {
                throw ToolError(message: "\(category): empty API or reason list")
            }
            result[category] = (reasons, apis)
        }
        return result
    }

    public static func possibleValueNames(_ doc: [String: Any]) throws -> [String] {
        let names = try possibleValues(DocCNode(doc)).map { try $0.string("name") ?? "" }
        guard !names.contains("") else {
            throw ToolError(message: "a possible value has no name")
        }
        return names
    }

    public static func text(_ doc: [String: Any]) throws -> String {
        let page = DocCNode(doc)
        let references = try page.node("references")
        var lines = [try page.node("metadata").string("title") ?? "", try inlineText(page.nodes("abstract"), references: references)]
        for section in try page.nodes("primaryContentSections") {
            guard section.kind == "content" else {
                throw ToolError(message: "unknown DocC section kind \(quoted(section.kind))")
            }
            lines += try blockLines(section.nodes("content"), references: references)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func possibleValues(_ page: DocCNode) throws -> [DocCNode] {
        let sections = try page.nodes("primaryContentSections").filter { $0.kind == "possibleValues" }
        guard sections.count == 1, let section = sections.first else {
            throw ToolError(message: "expected one possibleValues section, found \(sections.count)")
        }
        let values = try section.nodes("values")
        guard !values.isEmpty else {
            throw ToolError(message: "possibleValues section is empty")
        }
        return values
    }

    private static func singleBlock(_ value: DocCNode, kind: String, category: String) throws -> DocCNode {
        let blocks = try value.nodes("content").filter { $0.type == kind }
        guard blocks.count == 1, let block = blocks.first else {
            throw ToolError(message: "\(category): expected one \(kind), found \(blocks.count)")
        }
        return block
    }

    private static func apiEntry(_ item: DocCNode, references: DocCNode, category: String) throws -> (api: String, docc: String?) {
        let paragraphs = try item.nodes("content")
        guard paragraphs.count == 1, let paragraph = paragraphs.first, paragraph.type == "paragraph" else {
            throw ToolError(message: "\(category): unexpected API list item \(item.json)")
        }
        let nodes = try paragraph.nodes("inlineContent")
        guard nodes.count == 1, let node = nodes.first else {
            throw ToolError(message: "\(category): API list item has \(nodes.count) inline nodes")
        }
        switch node.type {
        case "reference":
            let identifier = try node.string("identifier") ?? ""
            guard let title = try references.node(identifier).string("title"), !title.isEmpty else {
                throw ToolError(message: "\(category): unresolved reference \(quoted(identifier))")
            }
            return (withoutArgumentLabels(title), identifier)
        case "codeVoice":
            return try (withoutArgumentLabels(node.string("code") ?? ""), nil)
        default:
            throw ToolError(message: "\(category): unknown inline node \(quoted(node.type)) in the API list")
        }
    }

    private static func reasonCode(_ item: DocCNode, category: String) throws -> String {
        let term = try item.node("term")
        let nodes = try term.nodes("inlineContent")
        guard nodes.count == 1, let node = nodes.first, node.type == "codeVoice", let code = try node.string("code") else {
            throw ToolError(message: "\(category): unexpected reason term \(term.json)")
        }
        return code
    }

    private static func definitionText(_ item: DocCNode, references: DocCNode) throws -> String {
        try item.node("definition").nodes("content")
            .map { try inlineText($0.nodes("inlineContent"), references: references) }
            .joined(separator: " ")
    }

    private static func inlineText(_ nodes: [DocCNode], references: DocCNode) throws -> String {
        try nodes.map { node in
            switch node.type {
            case "text":
                try node.string("text") ?? ""
            case "codeVoice":
                try node.string("code") ?? ""
            case "reference":
                try references.node(node.string("identifier") ?? "").string("title") ?? ""
            case "strong", "emphasis":
                try inlineText(node.nodes("inlineContent"), references: references)
            default:
                throw ToolError(message: "unknown DocC inline node \(quoted(node.type))")
            }
        }.joined()
    }

    private static func blockLines(_ blocks: [DocCNode], references: DocCNode) throws -> [String] {
        var lines: [String] = []
        for block in blocks {
            switch block.type {
            case "heading":
                let level = try block.integer("level") ?? 2
                let text = try block.string("text") ?? ""
                lines += ["", String(repeating: "#", count: max(level, 0)) + " " + text]
            case "paragraph":
                lines.append(try inlineText(block.nodes("inlineContent"), references: references))
            case "unorderedList", "orderedList":
                lines += try block.nodes("items").map { try "- " + blockLines($0.nodes("content"), references: references).joined(separator: " ") }
            case "codeListing":
                lines += try block.strings("code").map { "    " + $0 }
            case "aside":
                let name = try block.string("name") ?? "Note"
                lines.append(try "\(name): " + blockLines(block.nodes("content"), references: references).joined(separator: " "))
            case "table":
                lines += try block.rows("rows").map { row in
                    try row.map { try blockLines($0, references: references).joined(separator: " ") }.joined(separator: " | ")
                }
            default:
                throw ToolError(message: "unknown DocC block \(quoted(block.type))")
            }
        }
        return lines
    }

    private static func withoutArgumentLabels(_ title: String) -> String {
        guard title.hasSuffix(")"), let open = title.firstIndex(of: "(") else { return title }
        return String(title[..<open])
    }

    private static func quoted(_ value: String) -> String {
        String(reflecting: value)
    }

    private static func preview(_ data: Data) -> String {
        let head = data.prefix(80)
        return quoted(String(bytes: head, encoding: .utf8) ?? head.map { String(format: "%02x", $0) }.joined())
    }
}

private struct DocCNode {
    private let raw: [String: Any]

    init(_ raw: [String: Any]) {
        self.raw = raw
    }

    var type: String { raw["type"] as? String ?? "" }
    var kind: String { raw["kind"] as? String ?? "" }

    var json: String {
        guard JSONSerialization.isValidJSONObject(raw),
              let data = try? JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(bytes: data, encoding: .utf8) else { return "\(raw)" }
        return text
    }

    func string(_ key: String) throws -> String? {
        try value(key, as: String.self, described: "a string")
    }

    func integer(_ key: String) throws -> Int? {
        try value(key, as: Int.self, described: "an integer")
    }

    func strings(_ key: String) throws -> [String] {
        try value(key, as: [String].self, described: "a list of strings") ?? []
    }

    func node(_ key: String) throws -> DocCNode {
        DocCNode(try value(key, as: [String: Any].self, described: "an object") ?? [:])
    }

    func nodes(_ key: String) throws -> [DocCNode] {
        (try value(key, as: [[String: Any]].self, described: "a list of objects") ?? []).map(DocCNode.init)
    }

    func rows(_ key: String) throws -> [[[DocCNode]]] {
        let rows = try value(key, as: [[[[String: Any]]]].self, described: "a list of table rows") ?? []
        return rows.map { row in row.map { cell in cell.map(DocCNode.init) } }
    }

    private func value<Value>(_ key: String, as type: Value.Type, described description: String) throws -> Value? {
        guard let value = raw[key], !(value is NSNull) else { return nil }
        guard let typed = value as? Value else {
            throw ToolError(message: "DocC key \(String(reflecting: key)) is not \(description)")
        }
        return typed
    }
}
