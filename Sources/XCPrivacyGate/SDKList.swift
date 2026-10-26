import Foundation

package struct AppleSDKListing: Equatable, Sendable, Decodable {
    package let name: String
    package let listed: Bool

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case name
        case listed
    }

    package init(from decoder: Decoder) throws {
        try decoder.rejectUnknownKeys(of: CodingKeys.self)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        listed = try container.decode(Bool.self, forKey: .listed)
    }
}

package enum SDKList {
    package static let fileName = "apple/third-party-sdks.txt"

    private static let heading = "SDKs that require a privacy manifest and signature"
    private static let headingElements = "*[self::h1 or self::h2 or self::h3 or self::h4 or self::h5 or self::h6][normalize-space(.)='\(heading)']"

    package static func names(page: Data) throws -> [String] {
        let document: XMLDocument
        do {
            document = try XMLDocument(data: page, options: .documentTidyHTML)
        } catch {
            throw ToolError(message: "\(ApplePage.sdkList.address) is not readable HTML: \(error.localizedDescription)")
        }
        guard try !document.nodes(forXPath: "//\(headingElements)").isEmpty else {
            throw ToolError(message: "\(ApplePage.sdkList.address) no longer has the heading \(heading.pythonRepr)")
        }
        let names = try document.nodes(forXPath: "(//\(headingElements))[1]/following-sibling::ul[1]/li")
            .map { ($0.stringValue ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        guard !names.isEmpty else {
            throw ToolError(message: "\(ApplePage.sdkList.address) lists no SDKs under \(heading.pythonRepr)")
        }
        return names
    }

    package static func violation(names: [String], expected: AppleSDKListing?) -> Violation? {
        guard let expected else { return nil }
        let name = expected.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let onList = names.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(name) == .orderedSame }
        switch (onList, expected.listed) {
        case (true, false):
            return Violation(
                code: "SDK_ON_APPLE_LIST",
                module: nil,
                message: "Apple's list of \(heading) names \(name) (\(ApplePage.sdkList.address)): an app that includes \(name) "
                    + "must ship its privacy manifest, and a binary distribution of \(name) must be signed. "
                    + "Once reviewed, set appleSdkList.listed to true in the config"
            )
        case (false, true):
            return Violation(
                code: "SDK_OFF_APPLE_LIST",
                module: nil,
                message: "Apple's list of \(heading) no longer names \(name) (\(ApplePage.sdkList.address)), so that list no longer "
                    + "requires its privacy manifest and signature. Once reviewed, set appleSdkList.listed to false in the config"
            )
        default:
            return nil
        }
    }

    package static func read(_ file: URL) throws -> [String] {
        let text: String
        do {
            text = try String(contentsOf: file, encoding: .utf8)
        } catch {
            throw ToolError(message: "\(file.path): cannot read Apple's SDK list: \(error.localizedDescription)")
        }
        return text.split(separator: "\n").map(String.init)
    }

    static func text(_ names: [String]) -> String {
        names.map { "\($0)\n" }.joined()
    }
}
