import Foundation
import XCTest
@testable import BrewPeek

/// Migrated from StoreChecks: preserve saved data even when fresh collection/migration fails.
final class InventoryStoreTests: XCTestCase {
  private var snapshot: Record {
    ["formulae": [], "casks": [], "taps": [], "environment": ["updated": "test", "shell": "</script>\"한글"]]
  }

  func testCollectionFailurePreservesSavedJSONAndSchema() throws {
    let w = try CoreWorkspace(), output = w.url("inventory.json")
    try InventoryStore.save(snapshot, to: output)
    let before = try Data(contentsOf: output)
    XCTAssertEqual(try InventoryStore.load(output)["schemaVersion"] as? Int, 1)
    XCTAssertThrowsError(try Inventory(brew: "/usr/bin/false").generate(output: output))
    XCTAssertEqual(try Data(contentsOf: output), before)
  }

  func testInvalidSnapshotIsRejected() {
    XCTAssertThrowsError(try InventoryStore.decode(Data("{}".utf8)))
  }

  func testLegacyMigrationPreservesSpecialCharactersAndRemovesOldReport() throws {
    let w = try CoreWorkspace(), output = w.url("inventory.json")
    let json = String(decoding: try JSONSerialization.data(withJSONObject: snapshot), as: UTF8.self)
    try w.write("homebrew-inventory.html", "<script>\nconst brewData = " + json + ";\n</script>")
    try InventoryStore.migrateLegacy(to: output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: w.url("homebrew-inventory.html").path))
    XCTAssertEqual((try InventoryStore.load(output)["environment"] as? Record)?["shell"] as? String, "</script>\"한글")
  }

  func testUnreadableLegacyReportIsKept() throws {
    let w = try CoreWorkspace()
    try w.write("homebrew-inventory.html", "broken")
    XCTAssertThrowsError(try InventoryStore.migrateLegacy(to: w.url("inventory.json")))
    XCTAssertEqual(try String(contentsOf: w.url("homebrew-inventory.html"), encoding: .utf8), "broken")
  }
}
