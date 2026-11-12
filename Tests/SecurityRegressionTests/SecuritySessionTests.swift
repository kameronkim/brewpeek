import Foundation
import XCTest
@testable import BrewPeek

final class SecuritySessionTests: XCTestCase {
  func testSavingInventoryOmitsSessionSecurityAndKeepsOtherData() throws {
    let workspace = try SecurityWorkspace()
    for (name, status): (String, Int32) in [("complete-open",1),("incomplete-sbom",1),("complete-open",2)] {
      let snapshot = SecurityFixture.snapshot(check: try SecurityFixture.check(name,status:status))
      try InventoryStore.save(snapshot,to:workspace.inventory)
      let stored = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(contentsOf:workspace.inventory)) as? Record)
      XCTAssertNil(stored["securityCheck"])
      XCTAssertEqual(stored["snapshotID"] as? String,snapshot["snapshotID"] as? String)
      XCTAssertEqual((try InventoryStore.load(workspace.inventory)["formulae"] as? [Record])?.count,(snapshot["formulae"] as? [Record])?.count)
    }
  }

  func testLegacyReportIsDiscardedAndDisplayStartsWithChecking() throws {
    for check: Any in [try SecurityFixture.check("complete-open",status:1),["status":"failed","scope":"formulae","report":"invalid"],"corrupt legacy security"] {
      var snapshot = SecurityFixture.snapshot()
      snapshot["securityCheck"] = check
      let loaded = try InventoryStore.decode(SecurityFixture.canonical(snapshot))
      XCTAssertNil(loaded["securityCheck"])
      let display = InventoryStore.displaySnapshot(loaded)
      XCTAssertEqual((display["securityCheck"] as? Record)?["status"] as? String,"checking")
      XCTAssertNil((display["securityCheck"] as? Record)?["report"])
    }
  }
}
