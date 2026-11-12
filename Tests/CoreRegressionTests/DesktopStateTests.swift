import Cocoa
import XCTest
@testable import BrewPeek

/// Migrated from DesktopStateChecks; no package commands are started by these state transitions.
final class DesktopStateTests: XCTestCase {
  private var plan: PackageOperationPlan { .update(UpgradePlan(selected: [], packages: [], excluded: [])) }

  func testPreparationOwnershipCancellationAndCompletionReset() {
    var state = PackageOperationState()
    let first = state.beginPreparation(requestID: "first", rechecking: false)
    XCTAssertEqual(state.phase,.preparing); XCTAssertTrue(state.isPreparing); XCTAssertFalse(state.isExecuting)
    state.plan = plan; state.blockedUpdateToken = "approved"
    let second = state.beginPreparation(requestID: "second", rechecking: true)
    XCTAssertFalse(first === second); XCTAssertEqual(state.phase,.rechecking); XCTAssertTrue(state.isExecuting)
    XCTAssertNil(state.plan); XCTAssertNil(state.blockedUpdateToken); XCTAssertNil(state.cancelledRequestID)
    XCTAssertEqual(state.finishPreparation("first"),.obsolete)
    XCTAssertFalse(state.complete("first")); XCTAssertTrue(state.control === second); XCTAssertEqual(state.requestID,"second")
    state.cancelledRequestID = "second"
    XCTAssertFalse(state.ownsPreparation("second")); XCTAssertEqual(state.finishPreparation("second"),.cancelled)
    XCTAssertNil(state.requestID); XCTAssertNil(state.control); XCTAssertFalse(state.hasPlan); XCTAssertEqual(state.phase,.idle)
    _ = state.beginPreparation(requestID:"third",rechecking:false)
    XCTAssertEqual(state.finishPreparation("third"),.ready); XCTAssertEqual(state.requestID,"third")
    state.phase = .running; state.blockedUpdateToken = "blocked"; state.plan = plan
    XCTAssertTrue(state.complete("third"))
    XCTAssertEqual(state.phase,.idle); XCTAssertNil(state.requestID); XCTAssertNil(state.cancelledRequestID)
    XCTAssertNil(state.control); XCTAssertNil(state.blockedUpdateToken); XCTAssertFalse(state.hasPlan)
  }

  func testRecoveryRetainsOnlyDisplayResultsAndReplaysErrorBeforePlan() {
    var web = WebRecoveryState(); web.keys = ["formula:fixture"]
    web.remember(["kind":"result","packages":[],"snapshot":["large":"inventory"],"recoveryID":"saved","pendingCleanup":true,"recovered":true])
    XCTAssertNil(web.lastResult?["snapshot"])
    web.remember(["kind":"cleanupDiscarded"])
    for key in ["recoveryID","pendingCleanup","recovered"] { XCTAssertNil(web.lastResult?[key]) }
    web.remember(["kind":"checking","operation":"uninstall"])
    web.remember(["kind":"error","message":"fixture failure"])
    let replay = web.replayEvents(plan:plan,requestID:"current")
    XCTAssertEqual(replay.compactMap { $0["kind"] as? String },["result","checking","error"])
    XCTAssertEqual(replay.last?["operation"] as? String,"uninstall")
    XCTAssertEqual(replay.last?["retryKeys"] as? [String],web.keys)
    web.beginRecovery()
    XCTAssertTrue(web.isRecovering); XCTAssertFalse(web.isLoading); XCTAssertFalse(web.isRestoring)
    XCTAssertNotNil(web.lastResult); XCTAssertNotNil(web.pendingEvent)
    web.isLoading = true; web.isRestoring = true; web.finishRecovery()
    XCTAssertFalse(web.isRecovering); XCTAssertFalse(web.isLoading); XCTAssertFalse(web.isRestoring)
    XCTAssertNil(web.pendingEvent); XCTAssertNotNil(web.lastResult)
    let pendingPlan = web.replayEvents(plan:plan,requestID:"confirm")
    XCTAssertEqual(pendingPlan.count,2); XCTAssertEqual(pendingPlan.last?["requestID"] as? String,"confirm")
    web.beginRecovery(); web.remember(["kind":"plan","plan":plan.record])
    XCTAssertEqual(web.pendingEvent?["kind"] as? String,"plan")
    web.remember(["kind":"cancelled"])
    XCTAssertNil(web.pendingEvent); XCTAssertNotNil(web.lastResult)
    web.remember(["kind":"started","plan":plan.record])
    XCTAssertNil(web.pendingEvent); XCTAssertNil(web.lastResult)
  }

  func testNativeCancellationAcknowledgementStaleCallbacksAndRecoveryGate() throws {
    _ = NSApplication.shared
    let w = try CoreWorkspace(), app = DesktopApp(output:w.url("inventory.json"))
    _ = app.beginPackagePreparation(requestID:"cancelled")
    app.handleUpdate(["action":"cancel"])
    XCTAssertEqual(app.operation.cancelledRequestID,"cancelled"); XCTAssertTrue(app.busy)
    XCTAssertFalse(app.finishPreparation("cancelled")); XCTAssertFalse(app.busy); XCTAssertNil(app.operation.requestID)
    _ = app.beginPackagePreparation(requestID:"new")
    XCTAssertFalse(app.finishPreparation("old")); XCTAssertEqual(app.operation.requestID,"new"); XCTAssertTrue(app.busy)
    XCTAssertFalse(app.finishPackageOperation(["kind":"error"],requestID:"old"))
    XCTAssertEqual(app.operation.requestID,"new"); XCTAssertTrue(app.busy)
    XCTAssertTrue(app.beginPackageExecution(record:plan.record,requestID:"new"))
    XCTAssertTrue(app.operation.isExecuting); XCTAssertTrue(app.busy)
    XCTAssertTrue(app.finishPackageOperation(["kind":"result","packages":[]],requestID:"new"))
    XCTAssertFalse(app.busy); XCTAssertNil(app.operation.requestID); XCTAssertNotNil(app.webRecovery.lastResult)
    app.webRecovery.isRestoring = true; XCTAssertTrue(app.busy)
    app.webRecovery.finishRecovery(); XCTAssertFalse(app.busy)
    XCTAssertFalse(FileManager.default.fileExists(atPath:w.url("inventory.json").path))
  }

  func testDefaultInventoryLocationRemainsUnchanged() {
    _ = NSApplication.shared
    let expected = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
      .appendingPathComponent("BrewPeek").appendingPathComponent("inventory.json")
    XCTAssertEqual(DesktopApp().output,expected)
  }
}
