import AppKit
import XCTest

/// The menu bar shows images from the asset catalog by name, so a misspelt or missing one only shows as an
/// empty menu bar item.
final class MenuBarImageTests: XCTestCase {
    func testEveryMenuBarImageIsATemplateIn18Points() throws {
        for name in ["MenuBar", "MenuBar-attention", "MenuBar-failure"] {
            let image = try XCTUnwrap(NSImage(named: name), name)
            XCTAssertTrue(image.isTemplate, "\(name) must follow the menu bar's colour")
            XCTAssertEqual(image.size, NSSize(width: 18, height: 18), name)
        }
    }
}
