import Foundation
import XCTest
@testable import BrewPeek

final class FormulaSecurityTests: XCTestCase {
  func testCompleteOpenFindingsAcceptDocumentedExitOneAndPreserveReport() throws {
    let result = try SecurityFixture.check("complete-open", status: 1)
    XCTAssertEqual(result["status"] as? String, "succeeded")
    XCTAssertEqual(result["complete"] as? Bool, true)
    XCTAssertEqual(result["exitStatus"] as? Int, 1)
    XCTAssertEqual(try SecurityFixture.canonical(XCTUnwrap(result["report"] as? Record)),
      try SecurityFixture.canonical(SecurityFixture.report("complete-open")))
  }

  func testPatchedFindingsAndEmptyReportsAcceptExitZero() throws {
    for name in ["complete-patched", "complete-empty"] {
      let result = try SecurityFixture.check(name)
      XCTAssertEqual(result["status"] as? String, "succeeded", name)
      XCTAssertEqual(try SecurityFixture.canonical(XCTUnwrap(result["report"] as? Record)),
        try SecurityFixture.canonical(SecurityFixture.report(name)))
    }
    let report = try XCTUnwrap(SecurityFixture.check("complete-patched")["report"] as? Record)
    let finding = try XCTUnwrap((report["findings"] as? [Record])?.first)
    XCTAssertTrue(try XCTUnwrap(finding["vulnerabilities"] as? [Record]).isEmpty)
    XCTAssertEqual((finding["patched"] as? [Record])?.count, 1)
  }

  func testCoverageGapsRemainIncompleteWithTheirExpectedExitCodes() throws {
    for (name, code): (String, Int32) in [
      ("incomplete-skipped", 0), ("incomplete-sbom", 1),
      ("incomplete-untrusted", 1), ("incomplete-resolution", 1),
    ] {
      let result = try SecurityFixture.check(name, status: code)
      XCTAssertEqual(result["status"] as? String, "incomplete", name)
      XCTAssertEqual(result["complete"] as? Bool, false, name)
      XCTAssertEqual(try SecurityFixture.canonical(XCTUnwrap(result["report"] as? Record)),
        try SecurityFixture.canonical(SecurityFixture.report(name)))
    }
  }

  func testCoverageListsOverrideContradictoryCompleteFlagWithoutChangingRawReport() throws {
    var report = try SecurityFixture.report("incomplete-skipped")
    report["complete"] = true
    let input = Inventory.CommandResult(output: String(decoding: try SecurityFixture.canonical(report), as: UTF8.self), error: "", status: 0, exited: true)
    let result = FormulaSecurity.interpret(input)
    XCTAssertEqual(result["status"] as? String, "incomplete")
    XCTAssertEqual(result["complete"] as? Bool, false)
    XCTAssertEqual((result["report"] as? Record)?["complete"] as? Bool, true)
  }

  func testMalformedJSONMissingCoverageAndInvalidSchemaFailClosed() throws {
    for name in ["malformed", "missing-coverage", "invalid-schema"] {
      let result = try SecurityFixture.check(name, status: 1)
      XCTAssertEqual(result["status"] as? String, "failed", name)
      XCTAssertNil(result["report"], name)
    }
    for missing in ["checked", "complete", "findings", "skipped_formulae", "outdated_without_sbom", "unscanned_formulae"] {
      var report = try SecurityFixture.report("complete-empty")
      report.removeValue(forKey: missing)
      let input = Inventory.CommandResult(output: String(decoding: try SecurityFixture.canonical(report), as: UTF8.self), error: "", status: 0, exited: true)
      let result = FormulaSecurity.interpret(input)
      XCTAssertEqual(result["status"] as? String, "failed", missing)
      XCTAssertNil(result["report"], missing)
    }
    for text in ["", "[]", "{}", "not JSON"] {
      XCTAssertEqual(FormulaSecurity.interpret(.init(output: text, error: "fixture failure", status: 1, exited: true))["status"] as? String, "failed")
    }
  }

  func testUnexpectedExitsAndSignalsRetainValidButUnconfirmedFindings() throws {
    for (name, code, exited): (String, Int32, Bool) in [
      ("complete-open", 0, true), ("complete-open", 2, true),
      ("complete-open", 1, false), ("complete-empty", 1, true),
      ("incomplete-untrusted", 0, true), ("incomplete-skipped", 1, true),
    ] {
      let result = FormulaSecurity.interpret(try SecurityFixture.result(name, status: code, exited: exited))
      XCTAssertEqual(result["status"] as? String, "failed")
      XCTAssertNotNil(result["report"])
      XCTAssertTrue((result["error"] as? String)?.contains("not confirmed") == true)
    }
  }

  func testSavedInvalidSecurityCannotBreakInventoryLoading() throws {
    let snapshot = SecurityFixture.snapshot(check: ["status": "succeeded", "scope": "formulae", "report": ["findings": "bad"]])
    let loaded = try InventoryStore.decode(SecurityFixture.canonical(snapshot))
    XCTAssertEqual((loaded["securityCheck"] as? Record)?["status"] as? String, "failed")
    XCTAssertEqual(loaded["snapshotID"] as? String, "snapshot-A")
  }
}
