import Foundation
import Testing
import XCPrivacyGate

private let heading = "SDKs that require a privacy manifest and signature"

private func savedNames() throws -> [String] {
    try SDKList.names(page: Data(contentsOf: testData("apple/third-party-sdks-2026-10-25.html")))
}

private func listing(_ name: String, listed: Bool) throws -> AppleSDKListing {
    let json = try JSONSerialization.data(withJSONObject: ["name": name, "listed": listed])
    return try JSONDecoder().decode(AppleSDKListing.self, from: json)
}

@Suite("Apple's SDK list")
struct SDKListTests {
    @Test("the saved page lists the SDKs in page order")
    func savedPageListsSdksInPageOrder() throws {
        let names = try savedNames()

        #expect(names.count == 86)
        #expect(names.prefix(5) == ["Abseil", "AFNetworking", "Alamofire", "AppAuth", "BoringSSL / openssl_grpc"])
        #expect(names.last == "webview_flutter_wkwebview")
    }

    @Test("a page without the heading is a tool error naming the heading")
    func pageWithoutHeadingIsAnError() throws {
        let page = "<html><body><h4>Signatures for SDKs</h4><ul><li>Sample</li></ul></body></html>"

        let error = #expect(throws: ToolError.self) { try SDKList.names(page: Data(page.utf8)) }

        #expect(try #require(error).message.contains(heading))
    }

    @Test("a heading with an empty list is a tool error", arguments: ["<ul></ul>", "<ul><li> </li></ul>", "<p>None yet.</p>"])
    func headingWithEmptyListIsAnError(list: String) throws {
        let page = "<html><body><h4>\(heading)</h4>\(list)</body></html>"

        let error = #expect(throws: ToolError.self) { try SDKList.names(page: Data(page.utf8)) }

        #expect(try #require(error).message.contains("lists no SDKs"))
    }

    @Test("a configured SDK on Apple's list that the config marks as not listed is SDK_ON_APPLE_LIST")
    func listedSdkMarkedNotListedIsOnAppleList() throws {
        let violation = try #require(SDKList.violation(names: savedNames(), expected: listing("Alamofire", listed: false)))

        #expect(violation.code == "SDK_ON_APPLE_LIST")
        #expect(violation.module == nil)
        #expect(violation.message.contains("names Alamofire"))
        #expect(violation.message.contains("privacy manifest"))
        #expect(violation.message.contains("signed"))
        #expect(violation.message.contains("appleSdkList.listed to true"))
    }

    @Test("a configured SDK absent from Apple's list that the config marks as listed is SDK_OFF_APPLE_LIST")
    func absentSdkMarkedListedIsOffAppleList() throws {
        let violation = try #require(SDKList.violation(names: savedNames(), expected: listing("Sample", listed: true)))

        #expect(violation.code == "SDK_OFF_APPLE_LIST")
        #expect(violation.message.contains("no longer names Sample"))
        #expect(violation.message.contains("appleSdkList.listed to false"))
    }

    @Test(
        "the configured name matches a listed name exactly, ignoring case and surrounding whitespace",
        arguments: [
            ("  alamofire\n", false, "SDK_ON_APPLE_LIST"),
            ("ALAMOFIRE", true, nil),
            ("Alamo", false, nil),
            ("Sample", false, nil)
        ] as [(String, Bool, String?)]
    )
    func nameMatchesIgnoringCaseAndWhitespace(name: String, listed: Bool, code: String?) throws {
        let violation = try SDKList.violation(names: savedNames(), expected: listing(name, listed: listed))

        #expect(violation?.code == code)
    }

    @Test("a config without appleSdkList gets no verdict")
    func noAppleSdkListGetsNoVerdict() throws {
        #expect(try SDKList.violation(names: savedNames(), expected: nil) == nil)
    }
}
