import Foundation
import XCTest
@testable import BrewPeek

final class UpgradePreparationTests: XCTestCase {
  func testPinnedExclusionsDoNotBlockOtherSelectedPackages() throws {
    let f = try UpgradeFixture()
    var info = UpgradeFixture.info("1.0",false)
    var formulas = try XCTUnwrap(info["formulae"] as? [Record])
    formulas.append(["name":"pinned","full_name":"pinned","versions":["stable":"2.0"],"installed":[["version":"1.0"]]])
    info["formulae"] = formulas
    try f.workspace.json("before.json",info)
    try f.workspace.json("metadata.json",UpgradeFixture.info("1.0",false))
    try f.workspace.write("targeted","")
    let plan = try f.engine.prepare(keys:["formula:node","formula:pinned"])
    XCTAssertEqual(plan.selected.count,1); XCTAssertEqual(plan.excluded,["pinned"])
  }

  func testInvalidSelectionsAndEmptyPlansAreRejected() throws {
    let f = try UpgradeFixture()
    for name in ["--help","node;touch /tmp/oops","../node","a/b/c/d",""] { XCTAssertFalse(HomebrewPackageName.isValid(name),name) }
    XCTAssertThrowsError(try f.engine.prepare(keys:["formula:--help"]))
    try f.workspace.write("plan","Warning: node already installed\n")
    XCTAssertThrowsError(try f.engine.prepare(keys:["formula:node"]))
  }

  func testHomebrewPlanParsingKeepsWarningsAndRejectsTruncationOrErrors() throws {
    XCTAssertEqual(try Upgrade.plannedNames("==> Would upgrade 1 dependent\nssl 2.0 -> 3.0\n"),["ssl"])
    XCTAssertEqual(try Upgrade.plannedNames("==> Would upgrade 2 outdated packages:\na 1 -> 2\nvendor/tap/b 1 -> 2\n"),["a","vendor/tap/b"])
    XCTAssertEqual(try Upgrade.plannedNames("==> Would upgrade 2 outdated packages\nnode 1 -> 2\nWarning: a diagnostic\nssl 2 -> 3\n"),["node","ssl"])
    XCTAssertEqual(try Upgrade.plannedNames("==> Would upgrade 1 requested outdated package\ntarget 1 -> 3\n==> Would `brew cleanup`\nWould remove: /fixture/target/1\n"),["target"])
    for text in [
      "==> Would upgrade 2 outdated packages\nnode 1 -> 2\nWarning: truncated\n",
      "==> Would upgrade 2 outdated packages\nnode 1 -> 2\nWarning: truncated\n==> Done\n",
      "==> Would upgrade 1 outdated package\nError: failed\nnode 1 -> 2\n",
    ] { XCTAssertThrowsError(try Upgrade.plannedNames(text),text) }
  }

  func testOperationLockRejectsConcurrentOwner() throws {
    let w = try CoreWorkspace()
    try Upgrade.withLock(at:w.url("inventory.json")) {
      XCTAssertThrowsError(try Upgrade.withLock(at:w.url("inventory.json")) {})
    }
  }

  func testCancellationAndTimeoutStopEveryPreparationPhaseWithoutMutation() throws {
    let w = try CoreWorkspace()
    try w.json("metadata.json",UpgradeFixture.info("1.0",false))
    try w.write("plan","==> Would upgrade 1 requested outdated package\nnode 1.0 -> 2.0\n")
    let brew = try w.brew(#"""
      case "$1 $*" in
        info*--installed*) phase=installed ;;
        info*) phase=metadata ;;
        upgrade*--dry-run*) phase=dry ;;
        *) touch MUTATED; exit 99 ;;
      esac
      if test "$phase" = "$(cat slow-phase)"; then trap '' TERM; exec /bin/sleep 10; fi
      if test "$phase" = dry; then cat plan; else cat metadata.json; fi
      """#)
    let engine = Upgrade(brew:brew)
    for phase in ["installed","dry","metadata"] {
      try w.write("slow-phase",phase)
      for cancel in [false,true] {
        let control = UpgradePreparation(timeout:cancel ? 10:0.25)
        if cancel { DispatchQueue.global().asyncAfter(deadline:.now()+0.25) { control.cancel() } }
        let start = ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try engine.prepare(keys:["formula:node"],control:control)) { error in
          XCTAssertTrue(error.localizedDescription.contains(cancel ? "cancelled":"timed out"),"\(phase): \(error)")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,2,phase)
        try Upgrade.withLock(at:w.url("inventory.json")) {}
      }
    }
    XCTAssertThrowsError(try engine.readOnly(["upgrade","node"],control:UpgradePreparation()))
    XCTAssertFalse(FileManager.default.fileExists(atPath:w.url("MUTATED").path))
  }
}
