import XCTest
@testable import App

/// Interface text never ends with an ellipsis, in any shipped language.
final class InterfaceTextTests: XCTestCase {
    private func values(_ language: String) throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/app/Resources/\(language).lproj/Localizable.strings")
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], url.path)
        XCTAssertFalse(table.isEmpty)
        return table
    }

    func testNoTranslationEndsWithAnEllipsis() throws {
        for language in AppLanguage.supported {
            for (key, value) in try values(language) where value.hasSuffix("…") || value.hasSuffix("...") {
                XCTFail("\(language): \"\(key)\" = \"\(value)\"")
            }
        }
    }

    func testLookupDropsTheEllipsisEvenWithoutATranslation() {
        XCTAssertEqual(UIStrings.withoutTrailingEllipsis("Saved passwords…"), "Saved passwords")
        XCTAssertEqual(UIStrings.withoutTrailingEllipsis("連線中 ..."), "連線中")
        XCTAssertEqual(UIStrings.withoutTrailingEllipsis("a … b"), "a … b")
        for language in AppLanguage.allCases where language != .system {
            for key in ["Saved passwords…", "Connecting…", "A key with no translation…"] {
                XCTAssertFalse(UIStrings.text(key, language: language).hasSuffix("…"), key)
            }
        }
    }
}
