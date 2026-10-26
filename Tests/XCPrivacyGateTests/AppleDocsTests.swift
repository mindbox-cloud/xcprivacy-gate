import Foundation
import Testing
import XCPrivacyGate

@Suite("Apple documentation pages")
struct AppleDocsTests {
    private static let requiredReasonPage = "nsprivacyaccessedapitype-2026-10-25.json"
    private static let tn3181Page = "apple/tn3181-2026-10-25.json"
    private static let fileTimestamp = "NSPrivacyAccessedAPICategoryFileTimestamp"
    private static let systemBootTime = "NSPrivacyAccessedAPICategorySystemBootTime"
    private static let diskSpace = "NSPrivacyAccessedAPICategoryDiskSpace"
    private static let activeKeyboards = "NSPrivacyAccessedAPICategoryActiveKeyboards"
    private static let userDefaults = "NSPrivacyAccessedAPICategoryUserDefaults"

    @Test("the required reason page has five categories and seventeen reasons")
    func parsesFiveCategoriesAndSeventeenReasons() throws {
        let result = try AppleDocs.requiredReasons(applePage(Self.requiredReasonPage))

        #expect(Set(result.keys) == [Self.fileTimestamp, Self.systemBootTime, Self.diskSpace, Self.activeKeyboards, Self.userDefaults])
        #expect(result.values.map(\.reasons.count).reduce(0, +) == 17)
        let diskReason = try #require(result[Self.diskSpace]?.reasons["E174.1"])
        #expect(diskReason.hasPrefix("Declare this reason to check whether there is sufficient disk space to write files"))
    }

    @Test("API list entries resolve reference and codeVoice nodes")
    func resolvesReferenceAndCodeVoiceNodes() throws {
        let entries = try #require(try AppleDocs.requiredReasons(applePage(Self.requiredReasonPage))[Self.fileTimestamp]).apis
        let doccByAPI = Dictionary(entries.map { ($0.api, $0.docc) }) { first, _ in first }

        #expect(doccByAPI["creationDate"] == "doc://com.apple.documentation/documentation/Foundation/FileAttributeKey/creationDate")
        #expect(doccByAPI.keys.contains("fstat"))
        #expect(doccByAPI["fstat"] == .some(nil))
    }

    @Test("an API that Apple lists in two categories appears in both")
    func sharedApiListedInBothCategories() throws {
        let result = try AppleDocs.requiredReasons(applePage(Self.requiredReasonPage))

        #expect(result[Self.fileTimestamp]?.apis.contains { $0.api == "getattrlist" } == true)
        #expect(result[Self.diskSpace]?.apis.contains { $0.api == "getattrlist" } == true)
    }

    @Test("an unknown inline node in the API list is a tool error naming it")
    func unknownInlineNodeIsAnError() throws {
        let page = try mutablePage(Self.requiredReasonPage)
        let possibleValues = try element(of: page, "primaryContentSections", where: "kind", is: "possibleValues")
        let firstValue = try #require((possibleValues["values"] as? NSArray)?.firstObject as? NSMutableDictionary)
        let apiList = try element(of: firstValue, "content", where: "type", is: "unorderedList")
        try #require(apiList["items"] as? NSMutableArray).add(["content": [["type": "paragraph", "inlineContent": [["type": "newThing"]]]]])

        let error = #expect(throws: ToolError.self) { try AppleDocs.requiredReasons(swiftPage(page)) }

        #expect(try #require(error).message.contains("newThing"))
    }

    @Test("a page without the possibleValues section is a tool error naming the section")
    func pageWithoutPossibleValuesIsAnError() throws {
        let page = try mutablePage(Self.requiredReasonPage)
        let sections = try #require(page["primaryContentSections"] as? NSArray)
        page["primaryContentSections"] = sections.filter { ($0 as? NSDictionary)?["kind"] as? String != "possibleValues" }

        let error = #expect(throws: ToolError.self) { try AppleDocs.requiredReasons(swiftPage(page)) }

        #expect(try #require(error).message.contains("possibleValues"))
    }

    @Test("collected data types are read from the saved page")
    func readsCollectedDataTypes() throws {
        let names = try AppleDocs.possibleValueNames(applePage("nsprivacycollecteddatatype-2026-10-25.json"))

        #expect(names.count == 35)
        #expect(names.contains("NSPrivacyCollectedDataTypeDeviceID"))
    }

    @Test("purposes are read from the saved page")
    func readsPurposes() throws {
        let names = try AppleDocs.possibleValueNames(applePage("nsprivacycollecteddatatypepurposes-2026-10-25.json"))

        #expect(names.count == 6)
        #expect(names.contains("NSPrivacyCollectedDataTypePurposeAppFunctionality"))
    }

    @Test("the text of the saved TN3181 page equals its saved text")
    func tn3181TextEqualsSavedText() throws {
        let saved = try String(contentsOf: testData("apple/tn3181-2026-10-25.txt"), encoding: .utf8)

        #expect(try AppleDocs.text(applePage(Self.tn3181Page)) == saved)
    }

    @Test("an unknown DocC block is a tool error naming it")
    func unknownBlockIsAnError() throws {
        let page = try mutablePage(Self.tn3181Page)
        let section = try #require((page["primaryContentSections"] as? NSArray)?.firstObject as? NSMutableDictionary)
        try #require(section["content"] as? NSMutableArray).add(["type": "video", "identifier": "x"])

        let error = #expect(throws: ToolError.self) { try AppleDocs.text(swiftPage(page)) }

        #expect(try #require(error).message.contains("\"video\""))
    }

    @Test(
        "a page that is not a JSON object is a tool error naming the source",
        arguments: [
            ("<!DOCTYPE html><html><body>Moved</body></html>", "is not JSON"),
            ("[1, 2]", "is not a DocC JSON object")
        ]
    )
    func pageThatIsNotAJSONObjectIsAnError(body: String, problem: String) throws {
        let source = "https://developer.apple.com/tutorials/data/documentation/technotes/tn3181.json"

        let error = #expect(throws: ToolError.self) { try AppleDocs.document(Data(body.utf8), from: source) }

        #expect(try #require(error).message.contains("\(source) \(problem)"))
    }

    private func mutablePage(_ name: String) throws -> NSMutableDictionary {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: testData(name)), options: .mutableContainers)
        return try #require(object as? NSMutableDictionary)
    }

    private func element(of parent: NSDictionary, _ key: String, where field: String, is value: String) throws -> NSMutableDictionary {
        let children = try #require(parent[key] as? NSArray)
        return try #require(children.lazy.compactMap { $0 as? NSMutableDictionary }.first { $0[field] as? String == value })
    }

    private func swiftPage(_ page: NSDictionary) throws -> [String: Any] {
        try #require(page as? [String: Any])
    }
}
