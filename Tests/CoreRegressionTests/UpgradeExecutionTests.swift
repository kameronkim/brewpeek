import Foundation
import XCTest
@testable import BrewPeek

/// Migrated from UpgradeChecks: logs are progress hints; receipts determine the result.
final class UpgradeExecutionTests: XCTestCase {
  func testPlanAndExecutionVerifyNewAndDiscoveredDependencies() throws {
    let f = try UpgradeFixture(), plan = try f.engine.prepare(keys:["formula:node"])
    XCTAssertEqual(plan.packages.count,2)
    let ssl = try XCTUnwrap(plan.packages.first { $0.name == "ssl" })
    XCTAssertTrue(ssl.current.isEmpty); XCTAssertEqual(ssl.relationship,"Required by node")
    XCTAssertTrue(try XCTUnwrap(plan.packages.first { $0.name == "node" }).relationship.isEmpty)
    XCTAssertEqual(plan.selected.first?.argument,"homebrew/core/node")
    XCTAssertTrue(f.workspace.commands.contains("upgrade --dry-run --no-ask homebrew/core/node"))
    var events:[Record]=[]
    let rows = try XCTUnwrap(f.engine.execute(plan) { events.append($0) }["packages"] as? [Record])
    XCTAssertEqual(rows.count,3)
    XCTAssertEqual(rows.filter { $0["outcome"] as? String == "installed" }.count,2)
    XCTAssertEqual(rows.first { $0["name"] as? String == "node" }?["outcome"] as? String,"updated")
    XCTAssertTrue(events.contains { ($0["packages"] as? [Record])?.count == 3 })
    XCTAssertTrue(events.contains { event in
      (event["packages"] as? [Record])?.contains { $0["name"] as? String == "extra" && $0["relationship"] as? String == "Required by node" && $0["reason"] as? String == "Detected during execution" } == true
    })
    XCTAssertEqual(rows.first { $0["name"] as? String == "extra" }?["relationship"] as? String,"Required by node")
  }

  func testPluralDependencyHeadingKeepsParentRelationship() throws {
    let f = try UpgradeFixture(), plan = try f.engine.prepare(keys:["formula:node"])
    let script = try String(contentsOf:f.workspace.url("brew-fixture"),encoding:.utf8)
    try f.workspace.write("brew-fixture",script.replacingOccurrences(of:"Installing node dependency: extra",with:"Installing dependencies for node: extra"))
    var events:[Record]=[]
    _ = try f.engine.execute(plan) { events.append($0) }
    XCTAssertTrue(events.contains { event in (event["packages"] as? [Record])?.contains { $0["name"] as? String == "extra" && $0["relationship"] as? String == "Required by node" } == true })
  }

  func testNonzeroExitRetainsVerifiedPartialSuccess() throws {
    let f = try UpgradeFixture(), plan = try f.engine.prepare(keys:["formula:node"])
    try f.workspace.write("fail","")
    try f.workspace.json("after.json",UpgradeFixture.info("1.0",true))
    let rows = try XCTUnwrap(f.engine.execute(plan) { _ in }["packages"] as? [Record])
    XCTAssertEqual(rows.first { $0["name"] as? String == "node" }?["outcome"] as? String,"failed")
    XCTAssertEqual(rows.first { $0["name"] as? String == "ssl" }?["outcome"] as? String,"installed")
  }

  func testMixedFormulaAndCompoundCaskVersionsRequireChangedInstallation() throws {
    let w = try CoreWorkspace()
    func mixed(_ updated:Bool)->Record {
      ["formulae":[["name":"node","full_name":"node","versions":["stable":"2.0"],"installed":[["version":updated ? "2.0":"1.0"]]]],
       "casks":[["token":"sample-app","full_token":"sample-app","version":"2.0,abcdef1234567890","installed":updated ? "2.0,abcdef1234567890":"1.0,oldbuild","artifacts":[["app":["Sample.app"]]]]]]
    }
    try w.json("before.json",mixed(false)); try w.json("after.json",mixed(true))
    try w.write("plan","==> Would upgrade 2 outdated packages\nnode 1.0 -> 2.0\nsample-app 1.0,oldbuild -> 2.0,abcdef1234567890\n")
    let brew = try w.brew(#"""
      case "$1" in
        --caskroom) pwd ;;
        info) if test -f done; then cat after.json; else cat before.json; fi ;;
        upgrade) case "$*" in *--dry-run*) cat plan ;; *) echo '==> Upgrading node'; echo '==> Upgrading sample-app'; touch done ;; esac ;;
        *) exit 99 ;;
      esac
      """#)
    let engine = Upgrade(brew:brew), plan = try engine.prepare(keys:["formula:node","cask:sample-app"])
    XCTAssertEqual(plan.packages.count,2)
    XCTAssertTrue(plan.selected.contains { $0.argument == "homebrew/cask/sample-app" })
    let rows = try XCTUnwrap(engine.execute(plan) { _ in }["packages"] as? [Record])
    XCTAssertTrue(rows.allSatisfy { $0["outcome"] as? String == "updated" })
    XCTAssertEqual(rows.first { $0["id"] as? String == "cask:sample-app" }?["actualVersion"] as? String,"2.0,abcdef1234567890")
    try w.remove("done"); try w.json("after.json",mixed(false))
    let unchanged = try XCTUnwrap(engine.execute(plan) { _ in }["packages"] as? [Record])
    XCTAssertTrue(unchanged.allSatisfy { $0["outcome"] as? String == "attention" })
  }
}
