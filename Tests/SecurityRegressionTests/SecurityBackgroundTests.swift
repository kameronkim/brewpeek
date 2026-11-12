import Foundation
import XCTest
@testable import BrewPeek

/// Migrated from SecurityBackgroundChecks, with fresh native state for each scenario.
final class SecurityBackgroundTests: XCTestCase {
  func testCollectionDefersScanAndNativeStartRemainsNonblocking() throws {
    let f = try BackgroundSecurityFixture()
    XCTAssertFalse(f.commands.contains("help vulns")); XCTAssertEqual(f.scans,0)
    XCTAssertEqual((f.snapshot["securityCheck"] as? Record)?["status"] as? String,"checking")
    try f.workspace.write("delayed","")
    // A generous watchdog releases the fixture if start accidentally waits for the scan.
    // This checks ordering rather than imposing a subsecond performance requirement.
    let release = f.workspace.root.appendingPathComponent("release")
    let watchdog = DispatchWorkItem { try? Data().write(to: release) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: watchdog)
    defer { watchdog.cancel() }
    f.start()
    XCTAssertFalse(FileManager.default.fileExists(atPath: release.path), "Start waited for the blocked scan")
    XCTAssertFalse(f.app.busy); XCTAssertEqual(f.app.operation.phase,.idle)
    try f.wait { f.scans == 1 }
    XCTAssertNotNil(f.app.securityInventory)
    try f.workspace.write("release","")
    try f.wait { f.app.latestSecurityReport != nil && f.app.securityGeneration == nil }
    XCTAssertEqual(f.app.latestSecurityReport?.report["status"] as? String,"succeeded")
    XCTAssertNil(try f.saved()["securityCheck"])
  }

  func testCancelledScanCannotPublishIntoCurrentSession() throws {
    let f = try BackgroundSecurityFixture()
    f.snapshot["snapshotID"] = UUID().uuidString
    try SecurityFixture.saveSnapshot(f.snapshot,to:f.workspace.inventory)
    try f.workspace.write("cancellable","")
    f.start(); try f.wait { f.scans == 1 }
    let owner = try XCTUnwrap(f.app.securityGeneration)
    f.app.cancelSecurityRefresh()
    try NativeTestWait.remains { f.app.securityInventory == nil && f.app.latestSecurityReport == nil }
    XCTAssertNotEqual(f.app.securityGeneration,owner)
    XCTAssertNil(f.app.securityInventory); XCTAssertNil(f.app.latestSecurityReport)
    XCTAssertNil(try f.saved()["securityCheck"])
  }

  func testMutationStartCancelsOwnedReadOnlyScan() throws {
    let f = try BackgroundSecurityFixture()
    try f.workspace.write("cancellable",""); f.start()
    try f.wait { f.scans == 1 }
    _ = f.app.beginPackagePreparation(requestID:"mutation-test")
    XCTAssertTrue(f.app.beginPackageExecution(record:[:],requestID:"mutation-test"))
    XCTAssertNil(f.app.securityInventory)
    XCTAssertTrue(f.app.operation.isExecuting)
    XCTAssertFalse(f.commands.contains { ["upgrade","install","uninstall"].contains(String($0.split(separator:" ").first ?? "")) })
  }

  func testCompletedResultReplayAndTerminationGateDoNotRestartScan() throws {
    let f = try BackgroundSecurityFixture(); f.start()
    try f.wait { f.app.latestSecurityReport != nil && f.app.securityGeneration == nil }
    let completedID = f.app.latestSecurityReport?.snapshotID, scans = f.scans
    f.start()
    XCTAssertEqual(f.app.latestSecurityReport?.snapshotID,completedID)
    XCTAssertNil(f.app.securityInventory); XCTAssertEqual(f.scans,scans)
    f.app.terminating = true; f.start()
    XCTAssertNil(f.app.securityInventory)
  }

  func testSupportCacheKeysByVersionButNeverReusesFindingsOrTransientFailures() throws {
    let f = try BackgroundSecurityFixture(), cache = FormulaSecurity.SupportCache()
    func check(_ version:String)->Record { FormulaSecurity.check(inventory:Inventory(brew:f.brew),supportCache:cache,brewVersion:version) }
    let help = f.commands.filter { $0 == "help vulns" }.count, scans = f.scans
    for _ in 0..<2 { XCTAssertEqual(check("A")["status"] as? String,"succeeded") }
    XCTAssertEqual(f.commands.filter { $0 == "help vulns" }.count,help+1); XCTAssertEqual(f.scans,scans+2)
    _ = check("B"); XCTAssertEqual(f.commands.filter { $0 == "help vulns" }.count,help+2)
    try f.workspace.write("broken",""); XCTAssertEqual(check("C")["status"] as? String,"failed")
    try f.remove("broken"); XCTAssertEqual(check("C")["status"] as? String,"succeeded")
    try f.workspace.write("unsupported","")
    let unsupportedHelp = f.commands.filter { $0 == "help vulns" }.count
    for _ in 0..<2 { XCTAssertEqual(check("D")["status"] as? String,"unsupported") }
    XCTAssertEqual(f.commands.filter { $0 == "help vulns" }.count,unsupportedHelp+1)
    try f.remove("unsupported"); XCTAssertEqual(check("E")["status"] as? String,"succeeded")
  }

  func testScanDoesNotWaitForInventoryLockOrRewriteTheFile() throws {
    let f = try BackgroundSecurityFixture(), before = try Data(contentsOf: f.workspace.inventory)
    try HomebrewOperationLock.withLock(at: f.workspace.inventory) {
      f.start()
      try f.wait { f.app.latestSecurityReport != nil && f.app.securityGeneration == nil }
      XCTAssertEqual(f.app.latestSecurityReport?.report["status"] as? String,"succeeded")
    }
    XCTAssertEqual(try Data(contentsOf: f.workspace.inventory),before)
    XCTAssertEqual(f.scans,1)
  }

  func testNewAppSessionScansAgainWithoutRestoringOldFindings() throws {
    let f = try BackgroundSecurityFixture(); f.start()
    try f.wait { f.app.latestSecurityReport != nil && f.app.securityGeneration == nil }
    let scans = f.scans
    let newApp = DesktopApp()
    defer { newApp.cancelSecurityRefresh() }
    let snapshot = InventoryStore.displaySnapshot(try f.saved())
    XCTAssertEqual((snapshot["securityCheck"] as? Record)?["status"] as? String,"checking")
    XCTAssertNil((snapshot["securityCheck"] as? Record)?["report"])
    newApp.observeSecuritySnapshot(snapshot)
    newApp.startSecurityRefresh(snapshot,using:Inventory(brew:f.brew))
    try f.wait { newApp.latestSecurityReport != nil && newApp.securityGeneration == nil }
    XCTAssertEqual(f.scans,scans+1)
    XCTAssertNil(try f.saved()["securityCheck"])
  }

  func testExecutionAndRefreshFailuresEndInterruptedCheckingState() throws {
    for kind in ["error","result"] {
      let f = try BackgroundSecurityFixture()
      try f.workspace.write("cancellable",""); f.start(); try f.wait { f.scans == 1 }
      let request = "failed-"+kind
      _ = f.app.beginPackagePreparation(requestID:request)
      XCTAssertTrue(f.app.beginPackageExecution(record:[:],requestID:request))
      XCTAssertTrue(f.app.finishPackageOperation(["kind":kind,"message":"fixture error","refreshError":"fixture refresh failed"],requestID:request))
      try f.wait { f.app.latestSecurityReport != nil && f.app.securityGeneration == nil }
      XCTAssertNil(try f.saved()["securityCheck"])
      XCTAssertNil(f.app.securityInventory); XCTAssertFalse(f.app.busy)
      XCTAssertEqual(f.app.latestSecurityReport?.report["error"] as? String,"The inventory could not be refreshed after the package operation. Refresh before checking security again.")
    }
  }

  func testFailureBeforeScannerStartupAlsoEndsChecking() throws {
    let f = try BackgroundSecurityFixture()
    _ = f.app.beginPackagePreparation(requestID:"before-scan")
    XCTAssertTrue(f.app.beginPackageExecution(record:[:],requestID:"before-scan"))
    XCTAssertTrue(f.app.finishPackageOperation(["kind":"error","message":"fixture failure"],requestID:"before-scan"))
    try f.wait { f.app.latestSecurityReport != nil && f.app.securityGeneration == nil }
    XCTAssertNil(try f.saved()["securityCheck"])
  }

  func testReplacementInventoryAvoidsObsoleteInterruptionError() throws {
    let f = try BackgroundSecurityFixture(); f.start()
    _ = f.app.beginPackagePreparation(requestID:"fresh-result")
    XCTAssertTrue(f.app.beginPackageExecution(record:[:],requestID:"fresh-result"))
    var fresh = f.snapshot
    fresh["snapshotID"] = UUID().uuidString; fresh["securityCheck"] = ["scope":"formulae","status":"unsupported"]
    try SecurityFixture.saveSnapshot(fresh,to:f.workspace.inventory)
    f.app.observeSecuritySnapshot(fresh)
    XCTAssertTrue(f.app.finishPackageOperation(["kind":"result","snapshot":fresh],requestID:"fresh-result"))
    try NativeTestWait.remains {
      f.app.latestSecurityReport == nil && f.app.securityGeneration == nil
    }
    let saved = try f.saved()
    XCTAssertEqual(saved["snapshotID"] as? String,fresh["snapshotID"] as? String)
    XCTAssertNil(saved["securityCheck"])
  }

  func testObsoleteDeliveryCannotCancelNewOwnerOrRestartDuringRefresh() throws {
    let f = try BackgroundSecurityFixture(), obsolete = f.snapshot
    f.snapshot["snapshotID"] = UUID().uuidString
    try SecurityFixture.saveSnapshot(f.snapshot,to:f.workspace.inventory)
    f.start(); let owner = f.app.securityGeneration
    f.app.startSecurityRefresh(obsolete,using:Inventory(brew:f.brew))
    XCTAssertEqual(f.app.securityGeneration,owner)
    XCTAssertEqual(f.app.securityContext?.id,f.snapshot["snapshotID"] as? String)
    try f.wait { f.app.latestSecurityReport != nil && f.app.securityGeneration == nil }
    f.app.cancelSecurityRefresh(); f.app.inventoryRefreshState = "refreshing"; f.start()
    XCTAssertNil(f.app.securityInventory)
    f.app.inventoryRefreshState = "idle"
  }
}
