import Cocoa
import XCTest
@testable import BrewPeek

/// Native lifecycle integration with local command fixtures; no WebKit window or real trust writes.
final class DesktopSecurityRefreshTests: XCTestCase {
  private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    let limit = Date().addingTimeInterval(5)
    while !condition() && Date() < limit {
      RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(condition(), "Native security callback timed out", file: file, line: line)
  }

  private func app(snapshot: Record, destination: URL) -> DesktopApp {
    XCTAssertTrue(Thread.isMainThread)
    _ = NSApplication.shared
    let app = DesktopApp()
    app.recoveryChecked = true
    app.observeSecuritySnapshot(snapshot, at: destination)
    return app
  }

  func testTrustInvalidationBypassesCachedResultAndRefreshSurvivesUpdateCancellation() throws {
    let fixture = try SecurityCommandFixture()
    let old = try SecurityFixture.check("incomplete-untrusted", status: 1)
    let snapshot = SecurityFixture.snapshot(check: old)
    try SecurityFixture.saveSnapshot(snapshot, to: fixture.workspace.inventory)
    let app = app(snapshot: snapshot, destination: fixture.workspace.inventory)
    defer { app.cancelSecurityRefresh() }
    app.latestSecurityReport = ("snapshot-A", old)
    app.startSecurityRefresh(snapshot, using: Inventory(brew: fixture.brew), at: fixture.workspace.inventory)
    XCTAssertTrue(fixture.commands.isEmpty, "Completed results are normally reused")
    let context = app.invalidateSecurityForTrustChange()
    XCTAssertEqual(context?.id, "snapshot-A")
    XCTAssertEqual(app.latestSecurityReport?.report["status"] as? String, "checking")
    app.refreshSecurityAfterTrustChange(context, brew: fixture.brew)
    // Cancelling the subsequent package confirmation must not cancel this independent scan.
    app.operation.plan = .update(UpgradePlan(selected: [], packages: [], excluded: []))
    app.operation.requestID = "update-confirmation"
    app.handleUpdate(["action": "cancel"])
    XCTAssertFalse(app.operation.hasPlan)
    waitUntil { app.securityGeneration == nil && app.latestSecurityReport?.report["status"] as? String == "succeeded" }
    let latest = try XCTUnwrap(app.latestSecurityReport?.report["report"] as? Record)
    XCTAssertEqual((latest["findings"] as? [Record])?.count, 1, "Trust never implies a finding-free result")
    let saved = try XCTUnwrap(InventoryStore.load(fixture.workspace.inventory)["securityCheck"] as? Record)
    XCTAssertEqual(saved["status"] as? String, "succeeded")
    XCTAssertEqual(fixture.commands, ["help vulns", "vulns --json"])
  }

  func testInFlightPreTrustScanAndItsLateSaveCannotReplaceRefreshedResult() throws {
    let fixture = try SecurityCommandFixture(report: "incomplete-untrusted")
    try fixture.workspace.write("delayed", "")
    let pending: Record = ["scope": "formulae", "status": "checking"]
    let snapshot = SecurityFixture.snapshot(check: pending)
    try SecurityFixture.saveSnapshot(snapshot, to: fixture.workspace.inventory)
    let app = app(snapshot: snapshot, destination: fixture.workspace.inventory)
    defer { app.cancelSecurityRefresh() }
    app.startSecurityRefresh(snapshot, using: Inventory(brew: fixture.brew), at: fixture.workspace.inventory)
    waitUntil { FileManager.default.fileExists(atPath: fixture.workspace.root.appendingPathComponent("scan-started").path) }
    let previous = try XCTUnwrap(app.securityGeneration)
    let context = app.invalidateSecurityForTrustChange()
    XCTAssertFalse(previous.withCurrent { true })
    try FileManager.default.removeItem(at: fixture.workspace.root.appendingPathComponent("delayed"))
    try fixture.workspace.write("report.json", SecurityFixture.text("complete-open"))
    app.refreshSecurityAfterTrustChange(context, brew: fixture.brew)
    waitUntil { app.securityGeneration == nil && app.latestSecurityReport?.report["status"] as? String == "succeeded" }
    let before = try Data(contentsOf: fixture.workspace.inventory)
    XCTAssertFalse(try SecurityReportStore.update(SecurityFixture.check("incomplete-untrusted", status: 1), snapshotID: "snapshot-A", at: fixture.workspace.inventory, generation: previous))
    XCTAssertEqual(try Data(contentsOf: fixture.workspace.inventory), before)
    XCTAssertEqual(fixture.commands.filter { $0 == "vulns --json" }.count, 2)
    let latest = try XCTUnwrap(app.latestSecurityReport?.report["report"] as? Record)
    XCTAssertEqual((latest["findings"] as? [Record])?.count, 1)
  }
}
