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
    let bundle = w.url("Sample.app"), contents = bundle.appendingPathComponent("Contents")
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let bundleID = "test.brewpeek.sample"
    try PropertyListSerialization.data(
      fromPropertyList: ["CFBundlePackageType": "APPL", "CFBundleIdentifier": bundleID],
      format: .binary, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
    let closed = QuitCaskApp(packageID: "cask:sample-app", path: bundle.path, bundleID: bundleID)
    let wrongTap = QuitCaskApp(packageID: "cask:other/tap/sample-app", path: bundle.path, bundleID: bundleID)
    let replaced = QuitCaskApp(packageID: closed.packageID, path: bundle.path, bundleID: "test.other.app")
    func mixed(_ updated:Bool)->Record {
      ["formulae":[["name":"node","full_name":"node","versions":["stable":"2.0"],"installed":[["version":updated ? "2.0":"1.0"]]]],
       "casks":[["token":"sample-app","full_token":"sample-app","version":"2.0,abcdef1234567890","installed":updated ? "2.0,abcdef1234567890":"1.0,oldbuild","artifacts":[["app":["Sample.app"],"target":bundle.path]]]]]
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
    let result = try engine.execute(plan, quitApps: [closed, wrongTap, replaced]) { _ in }
    let targets = try XCTUnwrap(result["reopenApps"] as? [String: Record])
    XCTAssertEqual(targets.count, 1)
    XCTAssertEqual(targets.values.first?["packageID"] as? String, closed.packageID)
    XCTAssertEqual(targets.values.first?["path"] as? String, bundle.path)
    let rows = try XCTUnwrap(result["packages"] as? [Record])
    XCTAssertTrue(rows.allSatisfy { $0["outcome"] as? String == "updated" })
    XCTAssertEqual(rows.first { $0["id"] as? String == "cask:sample-app" }?["actualVersion"] as? String,"2.0,abcdef1234567890")
    try w.remove("done"); try w.json("after.json",mixed(false))
    let second = try engine.execute(plan, quitApps: [closed]) { _ in }
    XCTAssertNil(second["reopenApps"])
    let unchanged = try XCTUnwrap(second["packages"] as? [Record])
    XCTAssertTrue(unchanged.allSatisfy { $0["outcome"] as? String == "attention" })
  }
}
