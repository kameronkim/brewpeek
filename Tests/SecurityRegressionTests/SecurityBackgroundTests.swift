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
    XCTAssertEqual((try f.saved()["securityCheck"] as? Record)?["status"] as? String,"succeeded")
  }

  func testStaleSnapshotSaveAndCancelledScanCannotPublishIntoCurrentInventory() throws {
    let f = try BackgroundSecurityFixture(), oldID = try XCTUnwrap(f.snapshot["snapshotID"] as? String)
    f.snapshot["snapshotID"] = UUID().uuidString
    try SecurityFixture.saveSnapshot(f.snapshot,to:f.workspace.inventory)
    XCTAssertFalse(try SecurityReportStore.update(["status":"unsupported","scope":"formulae"],snapshotID:oldID,at:f.workspace.inventory))
    try f.workspace.write("cancellable","")
    f.start(); try f.wait { f.scans == 1 }
    let owner = try XCTUnwrap(f.app.securityGeneration)
    f.app.cancelSecurityRefresh()
    try NativeTestWait.remains { f.app.securityInventory == nil && f.app.latestSecurityReport == nil }
    XCTAssertFalse(owner.withCurrent { true })
    XCTAssertNil(f.app.securityInventory); XCTAssertNil(f.app.latestSecurityReport)
    XCTAssertEqual((try f.saved()["securityCheck"] as? Record)?["status"] as? String,"checking")
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

  func testPersistenceContentionRetriesWithoutRerunningScanner() throws {
    let f = try BackgroundSecurityFixture(), baseline = f.scans
    try HomebrewOperationLock.withLock(at:f.workspace.inventory) {
      f.start(); try f.wait { f.app.latestSecurityReport != nil }
      try NativeTestWait.remains { f.app.securityGeneration != nil }
      XCTAssertEqual(f.app.latestSecurityReport?.report["status"] as? String,"succeeded")
      XCTAssertNotNil(f.app.securityGeneration)
    }
    try f.wait { f.app.securityGeneration == nil }
    XCTAssertEqual((try f.saved()["securityCheck"] as? Record)?["status"] as? String,"succeeded")
    XCTAssertEqual(f.scans,baseline+1)
  }

  func testCancellationInvalidatesQueuedPersistenceRetries() throws {
    let f = try BackgroundSecurityFixture()
    try HomebrewOperationLock.withLock(at:f.workspace.inventory) {
      f.start(); try f.wait { f.app.latestSecurityReport != nil }
      try NativeTestWait.remains { f.app.securityGeneration != nil }
      f.app.cancelSecurityRefresh()
    }
    let before = try Data(contentsOf: f.workspace.inventory)
    try NativeTestWait.remains { (try? Data(contentsOf: f.workspace.inventory)) == before }
    f.app.startSecurityRefresh(f.snapshot,using:Inventory(brew:f.brew),at:f.workspace.inventory)
    XCTAssertNil(f.app.securityGeneration); XCTAssertNil(f.app.securityInventory); XCTAssertNil(f.app.latestSecurityReport)
    XCTAssertEqual((try f.saved()["securityCheck"] as? Record)?["status"] as? String,"checking")
  }

  func testNewInventoryIsPreservedWhenOldPersistenceRetryResumes() throws {
    let f = try BackgroundSecurityFixture(), newerID = UUID().uuidString
    try HomebrewOperationLock.withLock(at:f.workspace.inventory) {
      f.start(); try f.wait { f.app.latestSecurityReport != nil }
      f.snapshot["snapshotID"] = newerID
      try InventoryStore.save(f.snapshot,to:f.workspace.inventory)
    }
    try f.wait { f.app.securityGeneration == nil }
    let saved = try f.saved()
    XCTAssertEqual(saved["snapshotID"] as? String,newerID)
    XCTAssertEqual((saved["securityCheck"] as? Record)?["status"] as? String,"checking")
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
      XCTAssertEqual((try f.saved()["securityCheck"] as? Record)?["status"] as? String,"failed")
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
    XCTAssertEqual((try f.saved()["securityCheck"] as? Record)?["status"] as? String,"failed")
  }

  func testReplacementInventoryAvoidsObsoleteInterruptionError() throws {
    let f = try BackgroundSecurityFixture(); f.start()
    _ = f.app.beginPackagePreparation(requestID:"fresh-result")
    XCTAssertTrue(f.app.beginPackageExecution(record:[:],requestID:"fresh-result"))
    var fresh = f.snapshot
    fresh["snapshotID"] = UUID().uuidString; fresh["securityCheck"] = ["scope":"formulae","status":"unsupported"]
    try SecurityFixture.saveSnapshot(fresh,to:f.workspace.inventory)
    f.app.observeSecuritySnapshot(fresh,at:f.workspace.inventory)
    XCTAssertTrue(f.app.finishPackageOperation(["kind":"result","snapshot":fresh],requestID:"fresh-result"))
    try NativeTestWait.remains {
      f.app.latestSecurityReport == nil && f.app.securityGeneration == nil
    }
    let saved = try f.saved()
    XCTAssertEqual(saved["snapshotID"] as? String,fresh["snapshotID"] as? String)
    XCTAssertEqual((saved["securityCheck"] as? Record)?["status"] as? String,"unsupported")
  }

  func testObsoleteDeliveryCannotCancelNewOwnerOrRestartDuringRefresh() throws {
    let f = try BackgroundSecurityFixture(), obsolete = f.snapshot
    f.snapshot["snapshotID"] = UUID().uuidString
    try SecurityFixture.saveSnapshot(f.snapshot,to:f.workspace.inventory)
    f.start(); let owner = f.app.securityGeneration
    f.app.startSecurityRefresh(obsolete,using:Inventory(brew:f.brew),at:f.workspace.inventory)
    XCTAssertEqual(f.app.securityGeneration,owner)
    XCTAssertEqual(f.app.securityContext?.id,f.snapshot["snapshotID"] as? String)
    try f.wait { f.app.latestSecurityReport != nil && f.app.securityGeneration == nil }
    f.app.cancelSecurityRefresh(); f.app.inventoryRefreshState = "refreshing"; f.start()
    XCTAssertNil(f.app.securityInventory)
    f.app.inventoryRefreshState = "idle"
  }
}
