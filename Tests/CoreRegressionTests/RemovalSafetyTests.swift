import Foundation
import XCTest
@testable import BrewPeek

/// Regression-checks the product projection and execution path against pinned Homebrew helpers.
/// The upstream Ruby algorithms are pinned; all installed packages and receipts are doubles.
final class RemovalSafetyTests: XCTestCase {
  private struct Projection {
    let status: Int32
    let dependencies: [String]?
    let diagnostic: String
  }

  private func run(_ scenario: String, afterSelection: Bool = false,
                   capability: String = "supported") throws -> Projection {
    let folder = "Fixtures/HomebrewAutoremove"
    let fixture = try XCTUnwrap(Bundle.module.url(forResource: "projection_fixture", withExtension: "rb", subdirectory: folder))
    let workspace = try CoreWorkspace()
    var request: Record = ["type": scenario == "selected-formula" ? "formula" : "cask", "name": "remove-me"]
    if afterSelection {
      request["scope"] = scenario == "outside-scope" || scenario == "selected-formula" ? ["cmake"]
        : scenario == "chain" ? ["bar", "mid", "cmake"] : ["bar", "cmake"]
    }
    let encoded = try JSONSerialization.data(withJSONObject: request).base64EncodedString()
    let script = PackageRemoval.dependencyScript.replacingOccurrences(of: "PAYLOAD", with: "\"" + encoded + "\"")
    try workspace.write("projection.rb", script)
    let task = Process(), stdout = Pipe(), stderr = Pipe()
    task.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["BREWPEEK_TEST_RUBY"] ?? "/usr/bin/ruby")
    task.arguments = [fixture.path, scenario, afterSelection ? "after" : "before", capability, workspace.url("projection.rb").path]
    task.standardOutput = stdout; task.standardError = stderr
    try task.run()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let error = stderr.fileHandleForReading.readDataToEndOfFile()
    task.waitUntilExit()
    let record = try? JSONSerialization.jsonObject(with: output) as? Record
    return Projection(status: task.terminationStatus, dependencies: record?["dependencies"] as? [String],
                      diagnostic: String(decoding: error, as: UTF8.self))
  }

  func testKeptSourceBuildDependenciesAreProtected() throws {
    for scenario in ["cask-kept", "pinned", "cleanup-excluded", "outside-scope"] {
      for after in [false, true] {
        let result = try run(scenario, afterSelection: after)
        XCTAssertEqual(result.status, 0, result.diagnostic)
        XCTAssertEqual(result.dependencies, [], "\(scenario), after=\(after)")
      }
    }
  }

  func testSafetyPassRepeatsForDependenciesOfNewlyKeptCandidates() throws {
    for after in [false, true] {
      XCTAssertEqual(try run("chain", afterSelection: after).dependencies, [])
    }
  }

  func testExistingRuntimeProtectionAndOrdinaryRemovalRemainUnchanged() throws {
    for (scenario, expected) in [("runtime", [String]()), ("bottle", ["cmake"]), ("unused", ["bar", "cmake"])] {
      for after in [false, true] {
        let result = try run(scenario, afterSelection: after)
        XCTAssertEqual(result.status, 0, result.diagnostic)
        XCTAssertEqual(result.dependencies, expected, "\(scenario), after=\(after)")
      }
    }
  }

  func testExplicitlySelectedFormulaIsNotTreatedAsKept() throws {
    for after in [false, true] {
      let result = try run("selected-formula", afterSelection: after)
      XCTAssertEqual(result.status, 0, result.diagnostic)
      XCTAssertEqual(result.dependencies, ["cmake"])
    }
  }

  func testExecutionChecksReceiptMatchedScopeBeforeRemovingDependencies() throws {
    let fixture = try XCTUnwrap(Bundle.module.url(forResource: "projection_fixture", withExtension: "rb", subdirectory: "Fixtures/HomebrewAutoremove"))
    for capability in ["supported", "missing", "broken"] {
      let f = try RemovalFixture(dependencies: true)
      func formula(_ name: String, receipt: Int = 1) -> Record {
        var record = RemovalFixture.dependency(receipt: receipt)
        record["name"] = name; record["full_name"] = name
        return record
      }
      try f.workspace.json("before.json", ["formulae": [formula("bar"), formula("cmake")], "casks": [RemovalFixture.cask(dependencies: true)]])
      try f.workspace.json("before-plan.json", ["dependencies": ["bar", "cmake"], "blocked": [String]()])
      let plan = try f.removal.prepare(key: f.key)
      // bar changed since confirmation and must stay; its build dependency cmake
      // is unchanged. The *actual* Swift execution must narrow the Ruby scope first.
      let remaining: Record = ["formulae": [formula("bar", receipt: 2), formula("cmake")], "casks": [Record]()]
      try f.workspace.json("middle.json", remaining)
      try f.workspace.json("after.json", remaining)
      try f.workspace.write("fixture-path", fixture.path)
      try f.workspace.write("capability", capability)
      let path = f.workspace.url("brew-fixture")
      let script = try String(contentsOf: path, encoding: .utf8)
      let anchor = "if test -f done; then cat after-plan.json; else cat before-plan.json; fi"
      XCTAssertTrue(script.contains(anchor))
      try f.workspace.write("brew-fixture", script.replacingOccurrences(of: anchor, with: #"""
        if test -f done; then
          printf '%s' "$3" > execution-projection.rb
          exec "${BREWPEEK_TEST_RUBY:-/usr/bin/ruby}" "$(cat fixture-path)" unused after "$(cat capability)" "$PWD/execution-projection.rb"
        else cat before-plan.json; fi
        """#))
      let result = try f.removal.execute(plan) { _ in }
      let rows = try XCTUnwrap(result["packages"] as? [Record])
      XCTAssertEqual(rows.first?["outcome"] as? String, "uninstalled")
      XCTAssertFalse(f.workspace.commands.contains { $0.hasPrefix("uninstall --formula") }, capability)
      if capability == "broken" {
        XCTAssertTrue((result["details"] as? String)?.contains("fixture safety API failure") == true)
      } else {
        XCTAssertTrue(rows.dropFirst().allSatisfy { $0["outcome"] as? String == "kept" })
      }
    }
  }

  func testUnavailableSafetyAPIDoesNotFallBackToUnsafeCandidates() throws {
    let result = try run("cask-kept", capability: "missing")
    XCTAssertEqual(result.status, 0, result.diagnostic)
    XCTAssertEqual(result.dependencies, [])
  }

  func testSafetyAPIExecutionFailureDoesNotReturnCandidates() throws {
    let result = try run("cask-kept", capability: "broken")
    XCTAssertNotEqual(result.status, 0)
    XCTAssertNil(result.dependencies)
    XCTAssertTrue(result.diagnostic.contains("fixture safety API failure"))
  }
}
