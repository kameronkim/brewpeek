import Foundation
import XCTest
@testable import BrewPeek

/// Migrated from CommandEnvironmentChecks; only selected policy variables are printed.
final class CommandEnvironmentTests: XCTestCase {
  func testInventoryPreparationAndCommandsRemoveInheritedTrustBypass() throws {
    let key = "HOMEBREW_NO_REQUIRE_TAP_TRUST"
    let previous = getenv(key).map { String(cString:$0) }
    setenv(key,"1",1)
    defer {
      if let previous { setenv(key,previous,1) } else { unsetenv(key) }
    }
    let w = try SecurityWorkspace()
    try w.write("environment-brew",#"""
      #!/bin/sh
      if [ "${HOMEBREW_NO_REQUIRE_TAP_TRUST+x}" = x ]; then printf 'HOMEBREW_NO_REQUIRE_TAP_TRUST=%s\n' "$HOMEBREW_NO_REQUIRE_TAP_TRUST"; fi
      printf 'HOMEBREW_NO_AUTO_UPDATE=%s\n' "$HOMEBREW_NO_AUTO_UPDATE"
      printf 'HOMEBREW_NO_ANALYTICS=%s\n' "$HOMEBREW_NO_ANALYTICS"
      """#)
    let brew = w.root.appendingPathComponent("environment-brew").path
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:brew)
    let inventory = try Inventory(brew:brew).runResult(brew,["vulns","--json"])
    let process = BrewProcess(brew:brew)
    let preview = try process.readOnly(["info"],control:UpgradePreparation())
    let command = try process.command(["fixture"])
    for output in [inventory.output,preview,command.1] {
      XCTAssertFalse(output.contains(key+"="))
      XCTAssertTrue(output.contains("HOMEBREW_NO_AUTO_UPDATE=1"))
      XCTAssertTrue(output.contains("HOMEBREW_NO_ANALYTICS=1"))
    }
    XCTAssertEqual(getenv(key).map { String(cString:$0) },"1")
  }
}
