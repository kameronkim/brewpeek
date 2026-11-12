import Foundation
import XCTest
@testable import BrewPeek

/// Full native approval/recheck path; the only trust writes are in fixture JSON.
final class TrustSecurityIntegrationTests: XCTestCase {
  private func verifyRefresh(delayed:Bool = false,partial:Bool = false) throws {
    let f = try TrustTestFixture(formulaeOnly:true)
    if partial { try f.workspace.write("fail-second","") }
    let old:Record = ["scope":"formulae","status":"incomplete","report":["findings":[Record](),"checked":0,"complete":false,"skipped_formulae":[String](),"outdated_without_sbom":[String](),"unscanned_formulae":Dictionary(uniqueKeysWithValues:f.keys.map { (String($0.dropFirst(8)),"untrusted_tap") })]]
    let snapshot = SecurityFixture.snapshot(id:UUID().uuidString,check:old)
    try SecurityFixture.saveSnapshot(snapshot,to:f.workspace.inventory)
    let id = try XCTUnwrap(snapshot["snapshotID"] as? String)
    f.app.observeSecuritySnapshot(snapshot)
    f.app.latestSecurityReport = (id,old)
    let baseline = f.scans
    f.app.startSecurityRefresh(snapshot,using:Inventory(brew:f.brew))
    XCTAssertEqual(f.scans,baseline); XCTAssertNil(f.app.securityInventory)
    try f.workspace.write("delay-scan","")
    var previous:UUID?
    if delayed {
      f.app.latestSecurityReport = nil
      var pending = snapshot; pending["securityCheck"] = ["scope":"formulae","status":"checking"]
      f.app.startSecurityRefresh(pending,using:Inventory(brew:f.brew))
      try f.wait { FileManager.default.fileExists(atPath:f.workspace.root.appendingPathComponent("scan-started").path) }
      previous = f.app.securityGeneration
    }
    let consent = try f.requiredPlan()
    try f.workspace.write("delay-trust", "")
    f.approve(consent)
    try f.wait { FileManager.default.fileExists(atPath: f.workspace.root.appendingPathComponent("trust-started").path) }
    XCTAssertEqual(f.app.latestSecurityReport?.report["status"] as? String, "checking")
    if let previous { XCTAssertNotEqual(f.app.securityGeneration,previous) }
    try f.workspace.write("release-trust", "")
    if partial {
      try f.wait { f.app.operation.phase == .idle && !f.app.operation.hasPlan }
    } else {
      try f.wait { if case .update? = f.app.operation.plan { return true }; return false }
      XCTAssertNotNil(f.app.securityInventory)
      f.app.handleUpdate(["action":"cancel"])
      XCTAssertFalse(f.app.operation.hasPlan)
    }
    try f.wait { f.scans >= baseline + (delayed ? 2:1) }
    try f.workspace.write("release-scan","")
    try f.wait { f.app.securityGeneration == nil && f.app.latestSecurityReport?.report["report"] != nil }
    let fresh = try XCTUnwrap(f.app.latestSecurityReport?.report)
    let report = try XCTUnwrap(fresh["report"] as? Record)
    XCTAssertEqual(report["checked"] as? Int,partial ? 1:2)
    XCTAssertFalse(try XCTUnwrap(report["findings"] as? [Record]).isEmpty)
    XCTAssertEqual(fresh["status"] as? String,partial ? "incomplete":"succeeded")
    if let previous { XCTAssertNotEqual(f.app.securityGeneration,previous) }
    XCTAssertNil(try InventoryStore.load(f.workspace.inventory)["securityCheck"])
    let scans = f.scans
    f.app.startSecurityRefresh(snapshot,using:Inventory(brew:f.brew))
    XCTAssertEqual(f.scans,scans)
    XCTAssertFalse(f.commands.contains { $0.first == "upgrade" && !$0.contains("--dry-run") })
    XCTAssertEqual(f.writes.count,partial ? 1:2)
  }
  func testApprovedTrustInvalidatesCachedReportAndUpdateCancellationKeepsNewScan() throws { try verifyRefresh() }
  func testDelayedOldScanCannotOverwriteReportAfterApprovedTrust() throws { try verifyRefresh(delayed:true) }
  func testPartialTrustSaveFailureStillRescansActuallySavedState() throws { try verifyRefresh(partial:true) }
}
