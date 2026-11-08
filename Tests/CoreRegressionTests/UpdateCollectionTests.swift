import Foundation
import XCTest
@testable import BrewPeek

private final class UpdateFixture {
  let workspace: CoreWorkspace
  let inventory: Inventory
  init() throws {
    let w = try CoreWorkspace()
    workspace = w
    try w.json("info.json", ["formulae": [
      ["name": "alpha", "full_name": "alpha", "installed": [["version": "1.0", "installed_on_request": true]], "versions": ["stable": "99.0"]],
      ["name": "alpha", "full_name": "vendor/tools/alpha", "installed": [["version": "1.0"]]],
      ["name": "beta", "full_name": "beta", "installed": [["version": "1.0", "runtime_dependencies": [["full_name": "vendor/tools/alpha"]]]], "versions": ["stable": "2.0"]],
    ], "casks": [
      ["token": "sample", "installed": "1.0", "version": "2.0"],
      ["token": "self-updating", "installed": "1.0", "version": "2.0", "auto_updates": true],
    ]])
    let brew = try w.brew(#"""
      case "$1" in
        update) test ! -f fail-update ;;
        outdated) test ! -f fail-outdated || exit 1; cat outdated.json ;;
        info) cat info.json ;;
        leaves) echo alpha ;;
        tap) echo vendor/tools ;;
        --prefix|--cellar|--caskroom) echo "$PWD/missing" ;;
        --version) echo 'Homebrew fixture' ;;
        *) exit 99 ;;
      esac
      """#)
    inventory = Inventory(brew: brew)
    try w.write("outdated.json", #"{"formulae":[{"name":"alpha","current_version":"1.0_1","pinned":true},{"name":"vendor/tools/alpha","current_version":"3.0"}],"casks":[{"name":"sample","current_version":"2.0,42"}]}"#)
  }
}

/// Migrated from UpdateChecks, with a fresh command fixture for each independent scenario.
final class UpdateCollectionTests: XCTestCase {
  func testHomebrewDecisionsKeepTapIdentitiesRevisionsAndCaskExclusions() throws {
    let f = try UpdateFixture(), snapshot = try f.inventory.collect()
    let formulas = try XCTUnwrap(snapshot["formulae"] as? [Record])
    let casks = try XCTUnwrap(snapshot["casks"] as? [Record])
    XCTAssertEqual(formulas.count, 3); XCTAssertEqual(casks.count, 2)
    let core = try XCTUnwrap(formulas.first { $0["id"] as? String == "formula:alpha" })
    let tapped = try XCTUnwrap(formulas.first { $0["id"] as? String == "formula:vendor/tools/alpha" })
    let beta = try XCTUnwrap(formulas.first { $0["id"] as? String == "formula:beta" })
    let sample = try XCTUnwrap(casks.first { $0["id"] as? String == "cask:sample" })
    let selfUpdating = try XCTUnwrap(casks.first { $0["id"] as? String == "cask:self-updating" })
    XCTAssertEqual(core["leaf"] as? Bool, true)
    XCTAssertEqual(tapped["leaf"] as? Bool, false)
    XCTAssertEqual(core["usedBy"] as? [String], [])
    XCTAssertEqual(tapped["usedBy"] as? [String], ["beta"])
    XCTAssertEqual(core["availableVersion"] as? String, "1.0_1")
    XCTAssertEqual(tapped["availableVersion"] as? String, "3.0")
    XCTAssertNil(beta["availableVersion"] as? String)
    XCTAssertEqual(sample["availableVersion"] as? String, "2.0,42")
    XCTAssertNil(selfUpdating["availableVersion"] as? String)
    XCTAssertEqual((snapshot["updateCheck"] as? Record)?["status"] as? String, "succeeded")
    XCTAssertEqual(Array(f.workspace.commands.prefix(3)), ["update --quiet", "outdated --json=v2", "info --json=v2 --installed"])
  }

  func testSuccessfulEmptyCheckClearsPreviouslySavedAvailability() throws {
    let f = try UpdateFixture(), output = f.workspace.url("inventory.json")
    try InventoryStore.save(f.inventory.collect(), to: output)
    try f.workspace.write("outdated.json", #"{"formulae":[],"casks":[]}"#)
    try f.inventory.generate(output: output)
    let refreshed = try InventoryStore.load(output)
    XCTAssertTrue(try XCTUnwrap(refreshed["formulae"] as? [Record]).allSatisfy { $0["availableVersion"] as? String == nil })
    XCTAssertEqual((refreshed["updateCheck"] as? Record)?["status"] as? String, "succeeded")
  }

  func testCommandFailuresKeepInventoryWithoutUpdateClaims() throws {
    for marker in ["fail-update", "fail-outdated"] {
      let f = try UpdateFixture()
      try f.workspace.write(marker, "")
      let snapshot = try f.inventory.collect()
      XCTAssertEqual((snapshot["updateCheck"] as? Record)?["status"] as? String, "failed", marker)
      let formulas = try XCTUnwrap(snapshot["formulae"] as? [Record])
      XCTAssertEqual(formulas.count, 3)
      XCTAssertTrue(formulas.allSatisfy { $0["availableVersion"] as? String == nil })
    }
  }

  func testMalformedOutdatedResultDoesNotClaimPackagesAreCurrent() throws {
    let f = try UpdateFixture()
    try f.workspace.write("outdated.json", #"{"formulae":[{"name":"alpha"}],"casks":[]}"#)
    XCTAssertEqual((try f.inventory.collect()["updateCheck"] as? Record)?["status"] as? String, "failed")
  }

  func testCancelledInventoryCannotStartCommands() throws {
    let w = try CoreWorkspace(), inventory = Inventory(brew: "/usr/bin/false")
    inventory.cancel()
    XCTAssertThrowsError(try inventory.run("/usr/bin/touch", [w.url("unexpected").path]))
    XCTAssertFalse(FileManager.default.fileExists(atPath: w.url("unexpected").path))
  }

  func testCancellationStopsCommandIgnoringTermination() throws {
    let w = try CoreWorkspace()
    let slow = try w.executable("slow", "#!/bin/sh\ntrap '' TERM\nexec /bin/sleep 10\n")
    let inventory = Inventory(brew: slow)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { inventory.cancel() }
    let began = ProcessInfo.processInfo.systemUptime
    XCTAssertThrowsError(try inventory.run(slow, []))
    XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - began, 2)
  }
}
