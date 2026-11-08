import Foundation
import XCTest
@testable import BrewPeek

final class SecurityCommandTests: XCTestCase {
  func testActualChildExitOnePreservesValidFindingJSON() throws {
    let fixture = try SecurityCommandFixture()
    let result = FormulaSecurity.check(inventory: Inventory(brew: fixture.brew))
    XCTAssertEqual(result["status"] as? String, "succeeded")
    XCTAssertEqual(result["exitStatus"] as? Int, 1)
    XCTAssertNotNil(result["report"])
    XCTAssertEqual(fixture.commands, ["help vulns", "vulns --json"])
    // Ordinary run() must continue throwing for exit 1; only the scanner interprets it.
    XCTAssertThrowsError(try Inventory(brew: fixture.brew).run(fixture.brew, ["vulns", "--json"]))
  }

  func testActualChildUnexpectedFailureRetainsUnconfirmedReport() throws {
    let fixture = try SecurityCommandFixture(status: 2)
    let result = FormulaSecurity.check(inventory: Inventory(brew: fixture.brew))
    XCTAssertEqual(result["status"] as? String, "failed")
    XCTAssertNotNil(result["report"])
    XCTAssertTrue((result["diagnostic"] as? String)?.contains("Fixture command") == true)
  }

  func testCommandFailureWithoutJSONDoesNotBecomeFinding() throws {
    let fixture = try SecurityCommandFixture()
    try fixture.workspace.write("report.json", "")
    try fixture.workspace.write("status", "2")
    let result = FormulaSecurity.check(inventory: Inventory(brew: fixture.brew))
    XCTAssertEqual(result["status"] as? String, "failed")
    XCTAssertNil(result["report"])
  }

  func testUnsupportedAndBrokenHelpAreDifferent() throws {
    for (help, code, expected) in [
      ("Unknown command: vulns", "1", "unsupported"),
      ("Output --json only", "0", "unsupported"),
      ("Fixture help execution failed", "2", "failed"),
    ] {
      let fixture = try SecurityCommandFixture()
      try fixture.workspace.write("help.txt", help)
      try fixture.workspace.write("help-status", code)
      XCTAssertEqual(FormulaSecurity.check(inventory: Inventory(brew: fixture.brew))["status"] as? String, expected)
      XCTAssertEqual(fixture.commands, ["help vulns"])
    }
  }

  func testExecutableLaunchFailureIsReportedWithoutHomebrewLookup() throws {
    let workspace = try SecurityWorkspace()
    let missing = workspace.root.appendingPathComponent("missing-executable").path
    let result = FormulaSecurity.check(inventory: Inventory(brew: missing))
    XCTAssertEqual(result["status"] as? String, "failed")
    XCTAssertNotNil(result["error"])
    XCTAssertNil(result["report"])
  }

  func testTimeoutAndCancellationCannotReportSuccess() throws {
    let fixture = try SecurityCommandFixture()
    try fixture.workspace.write("slow", "")
    let result = FormulaSecurity.check(inventory: Inventory(brew: fixture.brew), timeout: 0.05)
    XCTAssertEqual(result["status"] as? String, "failed")
    XCTAssertTrue((result["error"] as? String)?.contains("timed out") == true)
    let cancelled = Inventory(brew: fixture.brew)
    cancelled.cancel()
    let before = fixture.commands
    XCTAssertEqual(FormulaSecurity.check(inventory: cancelled)["status"] as? String, "failed")
    XCTAssertEqual(fixture.commands, before)
  }
}
