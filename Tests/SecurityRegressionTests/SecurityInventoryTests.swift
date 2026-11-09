import Foundation
import XCTest
@testable import BrewPeek

/// The remaining SecurityChecks collection/persistence cases, beyond scanner-only tests.
final class SecurityInventoryTests: XCTestCase {
  private func fixture(report: String = "complete-open", status: String = "1") throws -> (SecurityWorkspace, Inventory) {
    let w = try SecurityWorkspace()
    try w.write("report.json", SecurityFixture.text(report)); try w.write("status",status)
    try w.write("help.txt","Output --json findings and scan coverage"); try w.write("help-status","0")
    let script = #"""
      #!/bin/sh
      cd "${0%/*}" || exit 97
      printf '%s\n' "$*" >> commands
      case "$1" in
        help) cat help.txt; exit "$(cat help-status)" ;;
        vulns) cat report.json; echo 'fixture diagnostic' >&2; exit "$(cat status)" ;;
        update) exit 0 ;;
        outdated) echo '{"formulae":[{"name":"alpha","current_version":"2"}],"casks":[{"name":"app","current_version":"3"}]}' ;;
        info) echo '{"formulae":[{"name":"alpha","installed":[{"version":"1"}]}],"casks":[{"token":"app","installed":"1"}]}' ;;
        leaves|tap) : ;;
        --prefix|--cellar|--caskroom) echo "$PWD/missing" ;;
        --version) echo 'Homebrew fixture' ;;
        *) exit 99 ;;
      esac
      """#
    try w.write("inventory-brew",script)
    let brew = w.root.appendingPathComponent("inventory-brew").path
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:brew)
    return (w,Inventory(brew:brew))
  }
  private func assertUpdates(_ snapshot: Record, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual((snapshot["updateCheck"] as? Record)?["status"] as? String,"succeeded",file:file,line:line)
    XCTAssertEqual((snapshot["formulae"] as? [Record])?.first?["availableVersion"] as? String,"2",file:file,line:line)
    XCTAssertEqual((snapshot["casks"] as? [Record])?.first?["availableVersion"] as? String,"3",file:file,line:line)
  }
  func testUnsupportedOldAndBrokenHelpDoNotDisableOrdinaryUpdates() throws {
    for (help,exit,status) in [("Unknown command: vulns","1","unsupported"),("Output --json","0","unsupported"),("fixture help failed","2","failed")] {
      let (w,inventory) = try fixture()
      try w.write("help.txt",help); try w.write("help-status",exit)
      let snapshot = try inventory.collect(includeSecurity:true)
      XCTAssertEqual((snapshot["securityCheck"] as? Record)?["status"] as? String,status)
      assertUpdates(snapshot)
      try InventoryStore.save(snapshot,to:w.inventory)
      let restored = try InventoryStore.load(w.inventory)
      XCTAssertEqual((restored["securityCheck"] as? Record)?["status"] as? String,status)
      let commands = try String(contentsOf:w.root.appendingPathComponent("commands"),encoding:.utf8)
      XCTAssertFalse(commands.split(separator:"\n").contains { ["upgrade","install","uninstall"].contains(String($0.split(separator:" ").first ?? "")) })
    }
  }
  func testScanOutcomesRemainIndependentOfUpdatesAndRetainReportsAfterSaving() throws {
    for (name,exit,status) in [("complete-open","1","succeeded"),("incomplete-sbom","1","incomplete"),("complete-open","2","failed")] {
      let (w,inventory) = try fixture(report:name,status:exit)
      let snapshot = try inventory.collect(includeSecurity:true)
      XCTAssertEqual((snapshot["securityCheck"] as? Record)?["status"] as? String,status)
      assertUpdates(snapshot)
      try InventoryStore.save(snapshot,to:w.inventory)
      let restored = try InventoryStore.load(w.inventory)
      XCTAssertNotNil((restored["securityCheck"] as? Record)?["report"])
      assertUpdates(restored)
    }
  }
  func testLegacySnapshotWithoutSecurityStillLoads() throws {
    let loaded = try InventoryStore.decode(SecurityFixture.canonical(SecurityFixture.snapshot()))
    XCTAssertNil(loaded["securityCheck"])
  }
}
