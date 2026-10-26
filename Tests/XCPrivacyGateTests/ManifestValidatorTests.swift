import Foundation
import Testing
import XCPrivacyGate

private let header = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">

    """

private let diagnostics = "<dict><key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeOtherDiagnosticData</string>"
    + "<key>NSPrivacyCollectedDataTypeLinked</key><true/>"
    + "<key>NSPrivacyCollectedDataTypeTracking</key><false/>"
    + "<key>NSPrivacyCollectedDataTypePurposes</key>"
    + "<array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array></dict>"

private func apiEntry(category: String = "NSPrivacyAccessedAPICategoryUserDefaults", reasons: [String] = ["CA92.1"]) -> String {
    "<dict><key>NSPrivacyAccessedAPIType</key><string>\(category)</string>"
        + "<key>NSPrivacyAccessedAPITypeReasons</key><array>\(reasons.map { "<string>\($0)</string>" }.joined())</array></dict>"
}

private func manifestXML(
    tracking: String? = "<false/>",
    domains: String? = "<array/>",
    collected: String? = "<array>\(diagnostics)</array>",
    apiTypes: String? = "<array>\(apiEntry())</array>",
    extra: String = ""
) -> String {
    let parts = [
        ("NSPrivacyTracking", tracking),
        ("NSPrivacyTrackingDomains", domains),
        ("NSPrivacyCollectedDataTypes", collected),
        ("NSPrivacyAccessedAPITypes", apiTypes)
    ].compactMap { key, value in value.map { "<key>\(key)</key>\($0)" } }
    return header + "<dict>" + parts.joined() + extra + "</dict></plist>\n"
}

@Suite("Manifest validation")
struct ManifestValidatorTests {
    private let rules: Rules

    init() throws {
        rules = try appleRules()
    }

    @Test("real SDK manifests are valid", arguments: ["Core", "Logger", "Notifications"])
    func realSDKManifestsAreValid(name: String) throws {
        let xml = try String(contentsOf: testData("manifests/\(name).xcprivacy"), encoding: .utf8)

        let (manifest, violations) = try check(xml)

        #expect(violations == [])
        let parsed = try #require(manifest)
        #expect(parsed.apiTypes == ["NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"]])
    }

    @Test("a duplicate key is rejected")
    func duplicateKeyIsRejected() throws {
        let message = try message(of: "MANIFEST_DUPLICATE_KEY", in: manifestXML(extra: "<key>NSPrivacyTracking</key><true/>"))

        #expect(message.contains("'NSPrivacyTracking'"))
    }

    @Test("Xcode's template placeholder is rejected")
    func xcodeTemplatePlaceholderIsRejected() throws {
        let message = try message(of: "MANIFEST_API_ENTRY_KEYS", in: manifestXML(apiTypes: "<array><dict/></array>"))

        #expect(message.contains("[]"))
    }

    @Test("a reason with a trailing space is rejected")
    func reasonWithTrailingSpaceIsRejected() throws {
        let message = try message(of: "MANIFEST_UNKNOWN_REASON", in: manifestXML(apiTypes: "<array>\(apiEntry(reasons: ["CA92.1 "]))</array>"))

        #expect(message.contains("'CA92.1 '"))
    }

    @Test("a shorthand category is rejected")
    func shorthandCategoryIsRejected() throws {
        let message = try message(of: "MANIFEST_UNKNOWN_CATEGORY", in: manifestXML(apiTypes: "<array>\(apiEntry(category: "UserDefaults"))</array>"))

        #expect(message.contains("'UserDefaults'"))
    }

    @Test("a reason from another category is rejected")
    func reasonFromOtherCategoryIsRejected() throws {
        let violations = try check(manifestXML(apiTypes: "<array>\(apiEntry(reasons: ["35F9.1"]))</array>")).violations

        let matching = violations.filter { $0.code == "MANIFEST_REASON_WRONG_CATEGORY" }
        #expect(matching.count == 1)
        #expect(matching.first?.message.contains("NSPrivacyAccessedAPICategorySystemBootTime") == true)
    }

    @Test("an empty API types array is rejected")
    func emptyApiTypesAreRejected() throws {
        #expect(try codes(manifestXML(apiTypes: "<array/>")).contains("MANIFEST_EMPTY_API_TYPES"))
    }

    @Test("an empty reasons array is rejected")
    func emptyReasonsAreRejected() throws {
        #expect(try codes(manifestXML(apiTypes: "<array>\(apiEntry(reasons: []))</array>")).contains("MANIFEST_EMPTY_REASONS"))
    }

    @Test("missing API types are allowed")
    func missingApiTypesAreAllowed() throws {
        let (manifest, violations) = try check(manifestXML(apiTypes: nil))

        #expect(violations == [])
        #expect(try #require(manifest).apiTypes == [:])
    }

    @Test("missing collected data is allowed")
    func missingCollectedDataIsAllowed() throws {
        #expect(try codes(manifestXML(collected: nil)) == [])
    }

    @Test("empty collected data is allowed")
    func emptyCollectedDataIsAllowed() throws {
        #expect(try codes(manifestXML(collected: "<array/>")) == [])
    }

    @Test("tracking must be false")
    func trackingMustBeFalse() throws {
        #expect(try codes(manifestXML(tracking: "<true/>")).contains("TRACKING_ENABLED"))
    }

    @Test("a missing tracking key is rejected while trackingDisabled is on")
    func missingTrackingIsRejectedWhileTrackingDisabledIsOn() throws {
        let message = try message(of: "MANIFEST_MISSING_KEY", in: manifestXML(tracking: nil))

        #expect(message.contains("missing key 'NSPrivacyTracking'; the SDK must declare false"))
    }

    @Test("a missing tracking key is allowed when trackingDisabled is off")
    func missingTrackingIsAllowedWhenTrackingDisabledIsOff() throws {
        let (manifest, violations) = try check(manifestXML(tracking: nil), trackingDisabled: false)

        #expect(violations == [])
        #expect(manifest != nil)
    }

    @Test("tracking domains are rejected while tracking is false")
    func domainsWithTrackingFalseAreRejected() throws {
        let message = try message(of: "TRACKING_DOMAINS", in: manifestXML(domains: "<array><string>api.example.com</string></array>"))

        #expect(message.contains("'api.example.com'"))
    }

    @Test("a collected data entry needs all four keys and Boolean flags")
    func collectedEntryNeedsFourKeysAndBooleans() throws {
        let threeKeys = diagnostics.replacing("<key>NSPrivacyCollectedDataTypeTracking</key><false/>", with: "")
        #expect(try codes(manifestXML(collected: "<array>\(threeKeys)</array>")).contains("MANIFEST_DATA_ENTRY_KEYS"))

        let stringBool = diagnostics.replacing(
            "<key>NSPrivacyCollectedDataTypeLinked</key><true/>",
            with: "<key>NSPrivacyCollectedDataTypeLinked</key><string>true</string>"
        )
        #expect(try codes(manifestXML(collected: "<array>\(stringBool)</array>")).contains("MANIFEST_TYPE"))
    }

    @Test("an unknown collected data type is rejected")
    func unknownDataTypeIsRejected() throws {
        let entry = diagnostics.replacing("NSPrivacyCollectedDataTypeOtherDiagnosticData", with: "NSPrivacyCollectedDataTypeDeviceId")

        let message = try message(of: "MANIFEST_UNKNOWN_DATA_TYPE", in: manifestXML(collected: "<array>\(entry)</array>"))

        #expect(message.contains("'NSPrivacyCollectedDataTypeDeviceId'"))
    }

    @Test("an unknown purpose is rejected")
    func unknownPurposeIsRejected() throws {
        let entry = diagnostics.replacing("NSPrivacyCollectedDataTypePurposeAppFunctionality", with: "App Functionality")

        let message = try message(of: "MANIFEST_UNKNOWN_PURPOSE", in: manifestXML(collected: "<array>\(entry)</array>"))

        #expect(message.contains("'App Functionality'"))
    }

    @Test("an unknown top-level key is rejected")
    func unknownTopLevelKeyIsRejected() throws {
        let message = try message(of: "MANIFEST_UNKNOWN_KEY", in: manifestXML(extra: "<key>NSPrivacyTrackingDomain</key><array/>"))

        #expect(message.contains("'NSPrivacyTrackingDomain'"))
    }

    @Test("a category listed twice is rejected")
    func duplicateCategoryEntryIsRejected() throws {
        let xml = manifestXML(apiTypes: "<array>\(apiEntry())\(apiEntry(reasons: ["1C8F.1"]))</array>")

        #expect(try codes(xml).contains("MANIFEST_DUPLICATE_ENTRY"))
    }

    @Test("a wrong-case file name is rejected")
    func wrongCaseFileNameIsRejected() throws {
        #expect(try codes(manifestXML(), fileName: "privacyinfo.xcprivacy") == ["MANIFEST_FILE_NAME"])
    }

    @Test("a missing file is reported")
    func missingFileIsReported() throws {
        let (manifest, violations) = try withTemporaryDirectory { directory in
            ManifestValidator.parse(directory.appendingPathComponent("PrivacyInfo.xcprivacy"), module: "Core", rules: rules, trackingDisabled: true)
        }

        #expect(manifest == nil)
        #expect(violations.map(\.code) == ["MANIFEST_MISSING_FILE"])
    }

    @Test("an unreadable property list is reported")
    func unreadablePlistIsReported() throws {
        #expect(try codes("<plist><dict><key>NSPrivacyTracking</dict>") == ["MANIFEST_UNREADABLE"])
    }

    @Test("tracking may be true when trackingDisabled is off")
    func trackingMayBeTrueWhenTrackingDisabledIsOff() throws {
        let trackedEntry = diagnostics.replacing(
            "<key>NSPrivacyCollectedDataTypeTracking</key><false/>",
            with: "<key>NSPrivacyCollectedDataTypeTracking</key><true/>"
        )
        let xml = manifestXML(tracking: "<true/>", domains: "<array><string>api.example.com</string></array>", collected: "<array>\(trackedEntry)</array>")

        let (manifest, violations) = try check(xml, trackingDisabled: false)

        #expect(violations == [])
        #expect(manifest != nil)
    }

    @Test("a tracking domain must be a bare host name while tracking is allowed", arguments: [
        ("https://api.example.com", "'https://api.example.com'"),
        ("example", "'example'"),
        ("api.example.com/sdk", "'api.example.com/sdk'"),
        ("api..example.com", "'api..example.com'"),
        ("api.example.com\n", "'api.example.com\\n'")
    ])
    func trackingDomainMustBeBareHostName(domain: String, shown: String) throws {
        let xml = manifestXML(tracking: "<true/>", domains: "<array><string>\(domain)</string></array>")

        let violations = try check(xml, trackingDisabled: false).violations

        #expect(violations.map(\.code) == ["TRACKING_DOMAINS"])
        #expect(violations.first?.message.contains("tracking domain \(shown) must be a bare host name") == true)
    }

    @Test("tracking needs at least one tracking domain", arguments: ["<array/>", nil])
    func trackingNeedsTrackingDomain(domains: String?) throws {
        let violations = try check(manifestXML(tracking: "<true/>", domains: domains), trackingDisabled: false).violations

        #expect(violations.map(\.code) == ["TRACKING_DOMAINS"])
        #expect(violations.first?.message.contains("NSPrivacyTrackingDomains lists no domain while NSPrivacyTracking is true") == true)
    }

    @Test("a binary property list manifest is read like the XML one")
    func binaryManifestIsReadLikeXML() throws {
        let xml = try Data(contentsOf: testData("manifests/Core.xcprivacy"))
        let binary = try PropertyListSerialization.data(
            fromPropertyList: PropertyListSerialization.propertyList(from: xml, format: nil),
            format: .binary,
            options: 0
        )

        let (manifest, violations) = try check(binary)

        #expect(violations == [])
        #expect(try #require(manifest).apiTypes == ["NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"]])
    }

    @Test("a file that is neither an XML nor a binary property list is unreadable")
    func fileInNeitherFormatIsUnreadable() throws {
        #expect(try codes("NSPrivacyTracking = false") == ["MANIFEST_UNREADABLE"])
    }

    @Test("CDATA sections count as key and string text")
    func cdataSectionsCountAsKeyAndStringText() throws {
        let xml = manifestXML(apiTypes: "<array>\(apiEntry(reasons: ["<![CDATA[CA92.1]]>"]))</array>")
            .replacing("<key>NSPrivacyTracking</key>", with: "<key><![CDATA[NSPrivacyTracking]]></key>")
            .replacing("<key>NSPrivacyTrackingDomains</key>", with: "<key><![CDATA[NSPrivacyTrackingDomains]]></key>")

        #expect(try codes(xml) == [])
    }

    @Test("a key inside an array is unreadable")
    func keyInsideArrayIsUnreadable() throws {
        #expect(try codes(manifestXML().replacing("<string>CA92.1</string>", with: "<key>CA92.1</key>")) == ["MANIFEST_UNREADABLE"])
    }

    @Test("text after the root dictionary is unreadable")
    func textAfterRootDictionaryIsUnreadable() throws {
        #expect(try codes(manifestXML().replacing("</dict></plist>", with: "</dict>stray</plist>")) == ["MANIFEST_UNREADABLE"])
    }

    @Test("an XML entity declaration makes the manifest unreadable", arguments: [
        "<!ENTITY unused \"CA92.1\">",
        "<!ENTITY % unused \"CA92.1\">",
        "<!NOTATION gif SYSTEM \"image/gif\"><!ENTITY unused SYSTEM \"unused.gif\" NDATA gif>",
        "<!ENTITY unused SYSTEM \"unused.xml\">"
    ])
    func entityDeclarationMakesManifestUnreadable(declaration: String) throws {
        let xml = manifestXML().replacing(
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">",
            with: "<!DOCTYPE plist [\(declaration)]>"
        )

        #expect(try codes(xml) == ["MANIFEST_UNREADABLE"])
    }

    @Test("a category spelled with a Kelvin sign look-alike is unknown")
    func categoryWithKelvinSignIsUnknown() throws {
        let category = "NSPrivacyAccessedAPICategoryActive\u{212A}eyboards"

        let message = try message(of: "MANIFEST_UNKNOWN_CATEGORY", in: manifestXML(apiTypes: "<array>\(apiEntry(category: category, reasons: ["3EC4.1"]))</array>"))

        #expect(message.unicodeScalars.contains("\u{212A}"))
    }

    private func check(_ xml: String, fileName: String = "PrivacyInfo.xcprivacy", trackingDisabled: Bool = true) throws -> (manifest: Manifest?, violations: [Violation]) {
        try check(Data(xml.utf8), fileName: fileName, trackingDisabled: trackingDisabled)
    }

    private func check(_ contents: Data, fileName: String = "PrivacyInfo.xcprivacy", trackingDisabled: Bool = true) throws -> (manifest: Manifest?, violations: [Violation]) {
        try withTemporaryDirectory { directory in
            try contents.write(to: directory.appendingPathComponent(fileName))
            return ManifestValidator.parse(directory.appendingPathComponent("PrivacyInfo.xcprivacy"), module: "Core", rules: rules, trackingDisabled: trackingDisabled)
        }
    }

    private func codes(_ xml: String, fileName: String = "PrivacyInfo.xcprivacy") throws -> [String] {
        try check(xml, fileName: fileName).violations.map(\.code)
    }

    private func message(of code: String, in xml: String) throws -> String {
        let violations = try check(xml).violations
        let violation = try #require(violations.first { $0.code == code }, "expected \(code), got \(violations.map(\.code))")
        return violation.message
    }
}
