import Foundation
import XCTest
@testable import BrewPeek

private final class RecoveryFixture {
  let workspace: CoreWorkspace
  let task: RemovalTask
  let removal: PackageRemoval
  var destination: URL { workspace.url("inventory.json") }
  static func formula(_ name:String,receipt:Int = 1)->Record {
    ["name":name,"full_name":name,"versions":["stable":"1"],"installed":[["version":"1","time":receipt,"installed_on_request":name == "root"]],"dependencies":[]]
  }
  init() throws {
    let w = try CoreWorkspace(); workspace = w
    let info:Record = ["formulae":[Self.formula("root"),Self.formula("parent"),Self.formula("child")],"casks":[]]
    let installed = Upgrade.packages(try Inventory.validateInstalledInfo(info))
    task = RemovalTask(PackageRemovalPlan(package:try XCTUnwrap(installed.first),dependencies:Array(installed.dropFirst())))
    try RemovalTaskStore.save(task,at:w.url("inventory.json"))
    try w.json("info.json",["formulae":[Self.formula("parent"),Self.formula("child")],"casks":[]])
    try w.json("plan.json",["dependencies":["parent","child"],"blocked":[]])
    try w.json("busy.json",["busy":[]]); try w.json("after.json",["formulae":[],"casks":[]]); try w.write("status","1")
    removal = PackageRemoval(brew:try w.brew(#"""
      case "$1" in
        info) cat info.json ;;
        ruby) case "$3" in *'"busy"'*) cat busy.json ;; *) cat plan.json ;; esac ;;
        uninstall) test "$HOMEBREW_NO_AUTOREMOVE" = 1 || exit 98
          code=$(cat status); if test "$code" = 0; then cp after.json info.json; fi; exit "$code" ;;
        *) exit 99 ;;
      esac
      """#))
  }
}

/// Migrated from CleanupRecoveryChecks, keeping retry/reopen and explicit discard independent.
final class CleanupRecoveryTests: XCTestCase {
  func testPersistenceAndRecoveryDoNotResumeCommandsAutomatically() throws {
    let f = try RecoveryFixture(), loaded = try XCTUnwrap(RemovalTaskStore.load(at:f.destination))
    XCTAssertEqual(loaded.id,f.task.id)
    XCTAssertEqual(loaded.dependencies.first?.receipt,f.task.dependencies.first?.receipt)
    XCTAssertEqual(try f.removal.recoveryResult(loaded)["pendingCleanup"] as? Bool,true)
    XCTAssertFalse(f.workspace.commands.contains { $0.hasPrefix("uninstall") })
    XCTAssertEqual(try f.removal.prepareCleanup(loaded).packages.count,2)
  }

  func testFailedCleanupRemainsRetryableAfterReopenAndSuccessfulRetryClearsTask() throws {
    let f = try RecoveryFixture(), plan = try f.removal.prepareCleanup(f.task)
    XCTAssertTrue(try RemovalTaskStore.finish(f.task,result:f.removal.executeCleanup(plan) { _ in },at:f.destination))
    let loaded = try XCTUnwrap(RemovalTaskStore.load(at:f.destination))
    XCTAssertEqual(try f.removal.recoveryResult(loaded)["pendingCleanup"] as? Bool,true)
    try f.workspace.write("status","0")
    let retry = try f.removal.prepareCleanup(loaded)
    XCTAssertFalse(try RemovalTaskStore.finish(loaded,result:f.removal.executeCleanup(retry) { _ in },at:f.destination))
    XCTAssertNil(try RemovalTaskStore.load(at:f.destination))
    XCTAssertFalse(f.workspace.commands.contains { $0.contains("uninstall") && $0.contains("homebrew/core/root") })
  }

  func testChangedReceiptsAndNewlySharedDependenciesAreKeptAndChangeFingerprint() throws {
    let f = try RecoveryFixture(), original = try f.removal.prepareCleanup(f.task)
    try f.workspace.json("info.json",["formulae":[RecoveryFixture.formula("parent",receipt:2),RecoveryFixture.formula("child")],"casks":[]])
    try f.workspace.json("plan.json",["dependencies":[],"blocked":[]])
    let changed = try f.removal.prepareCleanup(f.task)
    XCTAssertTrue(changed.packages.isEmpty); XCTAssertEqual(changed.kept.count,2)
    XCTAssertTrue(changed.kept.contains { $0["message"] as? String == "Installation changed since the original confirmation." })
    XCTAssertNotEqual(changed.fingerprint,original.fingerprint)
  }

  func testReinstalledRootAndBusyHomebrewBlockCleanup() throws {
    let f = try RecoveryFixture()
    try f.workspace.json("info.json",["formulae":[RecoveryFixture.formula("root"),RecoveryFixture.formula("child")],"casks":[]])
    XCTAssertThrowsError(try f.removal.prepareCleanup(f.task))
    try f.workspace.json("info.json",["formulae":[RecoveryFixture.formula("parent"),RecoveryFixture.formula("child")],"casks":[]])
    try f.workspace.json("busy.json",["busy":["child.formula.lock"]])
    XCTAssertThrowsError(try f.removal.prepareCleanup(f.task))
  }

  func testOnlyMatchingTaskCanBeExplicitlyDiscarded() throws {
    let f = try RecoveryFixture()
    XCTAssertThrowsError(try RemovalTaskStore.clear(at:f.destination,id:UUID().uuidString))
    XCTAssertNotNil(try RemovalTaskStore.load(at:f.destination))
    try RemovalTaskStore.clear(at:f.destination,id:f.task.id)
    XCTAssertNil(try RemovalTaskStore.load(at:f.destination))
  }
}
