import Foundation
import XCTest
@testable import BrewPeek

/// Migrated from UpgradeTrustChecks without modifying application sources at test time.
final class UpgradeTrustTests: XCTestCase {
  func testTapAndPackageTrustPreviewUseExactPathsWithoutTrustWrites() throws {
    for state in ["tap","package"] {
      let f = try TrustTestFixture(state:state)
      let before = try Data(contentsOf:f.workspace.root.appendingPathComponent("states"))
      let plan = try Upgrade(brew:f.brew).prepare(keys:f.keys)
      XCTAssertEqual(plan.selected.count,2)
      XCTAssertTrue(plan.selected.allSatisfy { $0.upgradeArgument.hasPrefix(f.workspace.root.path) })
      XCTAssertEqual(try Data(contentsOf:f.workspace.root.appendingPathComponent("states")),before)
      XCTAssertFalse(FileManager.default.fileExists(atPath:f.workspace.root.appendingPathComponent("implicit-write").path))
      let commands = try UpgradeTrust.commands(plan.selected,preview:true)
      XCTAssertEqual(commands.count,2)
      XCTAssertTrue(try XCTUnwrap(commands.first).contains("--formula"))
      XCTAssertTrue(try XCTUnwrap(commands.last).contains("--cask"))
      XCTAssertTrue(try UpgradeTrust.commands(plan.selected,preview:false).allSatisfy { !$0.contains("--dry-run") })
    }
  }

  func testSeparateFormulaAndCaskBatchesVerifyActualSuccessAndPartialFailure() throws {
    for partial in [false,true] {
      let f = try TrustTestFixture(state:"package")
      try f.workspace.write("execute-fixture","")
      if partial { try f.workspace.write("fail-cask","") }
      let engine = Upgrade(brew:f.brew), plan = try engine.prepare(keys:f.keys)
      let result = try engine.execute(plan) { _ in }
      let rows = try XCTUnwrap(result["packages"] as? [Record])
      XCTAssertEqual(result["exitCode"] as? Int32,partial ? 42:0)
      XCTAssertEqual(rows.first { $0["id"] as? String == f.keys.first }?["outcome"] as? String,"updated")
      XCTAssertEqual(rows.first { $0["id"] as? String == f.keys.last }?["outcome"] as? String,partial ? "skipped":"updated")
    }
  }

  func testOfficialTapsRemainImplicitAndUnsafePreviewNeverExecutes() throws {
    let f = try TrustTestFixture()
    let official = try UpgradeTrust.inspect(["formula:alpha","cask:app"],process:BrewProcess(brew:f.brew),control:UpgradePreparation())
    XCTAssertTrue(official.allSatisfy { $0.state == "official" })
    XCTAssertTrue(f.commands.isEmpty)
    XCTAssertThrowsError(try BrewProcess(brew:f.brew).readOnly(["upgrade","--dry-run","vendor/tools/alpha"],control:UpgradePreparation()))
    XCTAssertTrue(f.commands.isEmpty)
  }

  func testUntrustedPackagesRequireDedicatedConsentAndCancelCannotWrite() throws {
    let f = try TrustTestFixture(), plan = try f.requiredPlan()
    let before = try Data(contentsOf:f.workspace.root.appendingPathComponent("states"))
    XCTAssertTrue(f.commands.allSatisfy { $0.first == "ruby" })
    f.app.operation.plan = .trust(plan)
    f.app.handleUpdate(["action":"startTrust","token":"wrong","requestID":"bad"])
    XCTAssertTrue(f.writes.isEmpty)
    f.app.handleUpdate(["action":"cancel"])
    XCTAssertFalse(f.app.operation.hasPlan); XCTAssertTrue(f.writes.isEmpty)
    XCTAssertEqual(try Data(contentsOf:f.workspace.root.appendingPathComponent("states")),before)
  }

  func testApprovedTrustReturnsToSeparateUpdateConfirmationWithoutUpdating() throws {
    let f = try TrustTestFixture(), plan = try f.requiredPlan()
    f.approve(plan)
    try f.wait { if case .update? = f.app.operation.plan { return true }; return false }
    XCTAssertEqual(f.writes.count,2)
    XCTAssertFalse(FileManager.default.fileExists(atPath:f.workspace.root.appendingPathComponent("implicit-write").path))
    XCTAssertFalse(f.commands.contains { $0.first == "upgrade" && !$0.contains("--dry-run") })
    f.app.handleUpdate(["action":"cancel"])
  }

  func testChangedTapReferenceRequiresNewConsentBeforeAnyTrustWrite() throws {
    let f = try TrustTestFixture(), plan = try f.requiredPlan()
    try f.workspace.write("reference","https://changed.example/tap")
    f.approve(plan,request:"changed-source")
    try f.wait { if case .trust(let changed)? = f.app.operation.plan { return changed.token != plan.token }; return false }
    XCTAssertTrue(f.writes.isEmpty)
    f.app.handleUpdate(["action":"cancel"])
  }

  func testCancellationDuringTrustRecheckCannotSaveTrust() throws {
    let f = try TrustTestFixture(), plan = try f.requiredPlan()
    try f.workspace.write("slow-inspect","")
    f.approve(plan,request:"cancel-during-recheck")
    f.app.handleUpdate(["action":"cancel"])
    try f.wait { f.app.operation.phase == .idle }
    XCTAssertFalse(f.app.operation.hasPlan); XCTAssertTrue(f.writes.isEmpty)
  }
}
