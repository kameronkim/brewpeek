import Foundation
import XCTest
@testable import BrewPeek

/// Migrated from PackageRemovalChecks: command success alone never proves removal.
final class PackageRemovalTests: XCTestCase {
  private func rows(_ result: Record) throws -> [Record] { try XCTUnwrap(result["packages"] as? [Record]) }

  func testCaskPreparationIsReadOnlyAndRejectsInvalidSelection() throws {
    let f = try RemovalFixture(), plan = try f.removal.prepare(key:f.key)
    XCTAssertEqual(plan.package.argument,"vendor/tap/sample-app")
    XCTAssertFalse(f.workspace.commands.contains { $0.hasPrefix("uninstall") })
    for key in ["formula:sample-app","cask:--help","cask:../app","cask:missing","cask:app;touch-x"] {
      XCTAssertThrowsError(try f.removal.prepare(key:key),key)
    }
    let control = UpgradePreparation(); control.cancel()
    XCTAssertThrowsError(try f.removal.prepare(key:f.key,control:control))
  }

  func testCaskRemovalRequiresVerifiedAbsenceAndUsesOrdinaryUninstall() throws {
    let f = try RemovalFixture(), plan = try f.removal.prepare(key:f.key)
    var events:[Record]=[]
    let result = try f.removal.execute(plan) { events.append($0) }
    XCTAssertEqual(try rows(result).first?["outcome"] as? String,"uninstalled")
    XCTAssertEqual(result["verified"] as? Bool,true)
    XCTAssertTrue(events.contains { $0["kind"] as? String == "activity" })
    XCTAssertTrue(events.contains { $0["kind"] as? String == "verifying" })
    XCTAssertTrue(f.workspace.commands.contains("uninstall --cask vendor/tap/sample-app"))
    XCTAssertFalse(f.workspace.commands.contains { $0.contains("--force") || $0.contains("--zap") })
  }

  func testRemainingRegistrationErrorsAndInvalidVerificationNeverReportSuccess() throws {
    for (installed,code,expected) in [(true,"0","attention"),(true,"1","failed"),(false,"1","attention")] {
      let f = try RemovalFixture(), plan = try f.removal.prepare(key:f.key)
      try f.workspace.json("middle.json",["formulae":[],"casks":installed ? [RemovalFixture.cask()]:[]])
      try f.workspace.write("status",code)
      XCTAssertEqual(try rows(f.removal.execute(plan) { _ in }).first?["outcome"] as? String,expected)
    }
    let f = try RemovalFixture(), plan = try f.removal.prepare(key:f.key)
    try f.workspace.write("middle.json","invalid-json")
    let result = try f.removal.execute(plan) { _ in }
    XCTAssertEqual(try rows(result).first?["outcome"] as? String,"attention")
    XCTAssertEqual(result["verified"] as? Bool,false)
  }

  func testChangedInstallationRequiresNewConfirmation() throws {
    let f = try RemovalFixture(), original = try f.removal.prepare(key:f.key)
    try f.workspace.json("before.json",["formulae":[],"casks":[RemovalFixture.cask(version:"2.0",receipt:2)]])
    XCTAssertNotEqual(try f.removal.prepare(key:f.key).fingerprint,original.fingerprint)
    let dependencies = try RemovalFixture(dependencies:true)
    XCTAssertNotEqual(try dependencies.removal.prepare(key:dependencies.key).fingerprint,original.fingerprint)
  }

  func testDependenciesAreBoundedByConfirmationAndRecheckedAfterRemoval() throws {
    let f = try RemovalFixture(dependencies:true), plan = try f.removal.prepare(key:f.key)
    XCTAssertEqual(plan.dependencies.map(\.fullName),["unused"])
    XCTAssertTrue(try rows(f.removal.execute(plan) { _ in }).allSatisfy { $0["outcome"] as? String == "uninstalled" })
    XCTAssertTrue(f.workspace.commands.contains("uninstall --formula homebrew/core/unused"))
    XCTAssertFalse(f.workspace.commands.contains { $0.contains("--formula homebrew/core/unrelated") })
  }

  func testDependenciesNoLongerEligibleOrChangedAreKept() throws {
    for changed in [false,true] {
      let f = try RemovalFixture(dependencies:true), plan = try f.removal.prepare(key:f.key)
      try f.workspace.json("after-plan.json",["dependencies":changed ? ["unused"]:[],"blocked":[]])
      if changed { try f.workspace.json("middle.json",["formulae":[RemovalFixture.dependency(version:"2",receipt:2)],"casks":[]]) }
      XCTAssertEqual(try rows(f.removal.execute(plan) { _ in })[1]["outcome"] as? String,"kept")
      XCTAssertFalse(f.workspace.commands.contains { $0.hasPrefix("uninstall --formula") })
    }
  }

  func testCaskFailurePreventsDependencyRemovalAndInvalidDependencyIsRejected() throws {
    let f = try RemovalFixture(dependencies:true), plan = try f.removal.prepare(key:f.key)
    try f.workspace.write("status","1")
    _ = try f.removal.execute(plan) { _ in }
    XCTAssertFalse(f.workspace.commands.contains { $0.hasPrefix("uninstall --formula") })
    let invalid = try RemovalFixture(dependencies:true)
    try invalid.workspace.json("before-plan.json",["dependencies":["--force"],"blocked":[]])
    XCTAssertThrowsError(try invalid.removal.prepare(key:invalid.key))
  }

  func testDirectFormulaAndConfirmedUnusedDependenciesCanBeRemoved() throws {
    let f = try RemovalFixture(formula:true), plan = try f.removal.prepare(key:f.key)
    XCTAssertEqual(plan.package.type,"formula"); XCTAssertEqual(plan.dependencies.count,1)
    XCTAssertTrue(try rows(f.removal.execute(plan) { _ in }).allSatisfy { $0["outcome"] as? String == "uninstalled" })
  }

  func testFormulaFailureUsesDistinctSelectedAndDependencyMessages() throws {
    let f = try RemovalFixture(formula:true), plan = try f.removal.prepare(key:f.key)
    try f.workspace.json("middle.json",["formulae":[RemovalFixture.rootFormula(),RemovalFixture.dependency()],"casks":[]])
    try f.workspace.write("status","1")
    let result = try rows(f.removal.execute(plan) { _ in })
    XCTAssertEqual(result[0]["message"] as? String,"Still registered as installed. Review activity and retry.")
    XCTAssertEqual(result[1]["message"] as? String,"Dependency removal did not start. Review activity.")
  }

  func testDependencyOnlyPinnedAndRequiredFormulaeAreRejected() throws {
    let f = try RemovalFixture(formula:true)
    try f.workspace.json("before.json",["formulae":[RemovalFixture.rootFormula(requested:false),RemovalFixture.dependency()],"casks":[]])
    XCTAssertThrowsError(try f.removal.prepare(key:f.key)) { error in XCTAssertTrue(error.localizedDescription.contains("installed as a dependency")) }
    try f.workspace.json("before.json",["formulae":[RemovalFixture.rootFormula(),RemovalFixture.dependency()],"casks":[]])
    for blocker in ["consumer","Pinned Formula"] {
      try f.workspace.json("before-plan.json",["dependencies":[],"blocked":[blocker]])
      XCTAssertThrowsError(try f.removal.prepare(key:f.key)) { error in XCTAssertTrue(error.localizedDescription.contains(blocker)) }
    }
  }
}
