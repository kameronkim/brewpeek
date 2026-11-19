import XCTest
@testable import BrewPeek

final class PackageNotesTests: XCTestCase {
  func testWritesPreserveOtherIdentitiesAndRejectInvalidInputOrCorruptFiles() throws {
    let workspace = try CoreWorkspace()
    let file = workspace.url("notes.json")
    let store = PackageNotes(file: file)
    XCTAssertEqual(try store.read(), [:])
    XCTAssertEqual(try store.save(id: "formula:alpha/tools/demo", text: "  note  "), "note")
    _ = try store.save(id: "cask:demo", text: "app")
    XCTAssertThrowsError(try store.save(id: "other:demo", text: "invalid"))
    XCTAssertThrowsError(try store.save(id: "cask:demo", text: String(repeating: "x", count: 301)))
    XCTAssertEqual(try store.read(), ["formula:alpha/tools/demo": "note", "cask:demo": "app"])
    try workspace.write("notes.json", "broken")
    XCTAssertThrowsError(try store.save(id: "cask:demo", text: "new"))
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "broken")
  }
}
