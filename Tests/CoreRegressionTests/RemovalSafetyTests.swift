import Foundation
import XCTest
@testable import BrewPeek

/// Characterizes the current gap and regression-checks a proposal without changing product code.
/// The upstream Ruby algorithms are pinned; all installed packages and receipts are doubles.
final class RemovalSafetyTests: XCTestCase {
  private struct Projection {
    let status: Int32
    let dependencies: [String]?
    let diagnostic: String
  }

  private func run(_ scenario: String, afterSelection: Bool = false,
                   proposed: Bool = false, capability: String = "supported", scope: [String]? = nil) throws -> Projection {
    let folder = "Fixtures/HomebrewAutoremove"
    let fixture = try XCTUnwrap(Bundle.module.url(forResource: "projection_fixture", withExtension: "rb", subdirectory: folder))
    let workspace = try CoreWorkspace()
    var request: Record = ["type": scenario == "selected-formula" ? "formula" : "cask", "name": "remove-me"]
    if afterSelection {
      request["scope"] = scenario == "outside-scope" || scenario == "selected-formula" ? ["cmake"]
        : scenario == "chain" ? ["bar", "mid", "cmake"] : ["bar", "cmake"]
    }
    if let scope { request["scope"] = scope }
    let encoded = try JSONSerialization.data(withJSONObject: request).base64EncodedString()
    var script = PackageRemoval.dependencyScript.replacingOccurrences(of: "PAYLOAD", with: "\"" + encoded + "\"")
    if proposed {
      // Proposed change only: preserve the complete installed set (including cleanup
      // exclusions), minus the explicitly selected Formula. Unsupported API => no deps.
      let anchor = "names = removable.map(&:full_name).sort"
      XCTAssertTrue(script.contains(anchor))
      script = script.replacingOccurrences(of: anchor, with: #"""
        removable = if Utils::Autoremove.respond_to?(:formulae_safe_to_remove)
          Utils::Autoremove.formulae_safe_to_remove(removable, Formula.installed - [selected_formula])
        else
          []
        end
        names = removable.map(&:full_name).sort
        """#)
    }
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

  func testKeptSourceBuildDependenciesExposeGapAndProposedPassProtectsThem() throws {
    for scenario in ["cask-kept", "pinned", "cleanup-excluded", "outside-scope"] {
      for after in [false, true] {
        let current = try run(scenario, afterSelection: after)
        XCTAssertEqual(current.status, 0, current.diagnostic)
        XCTAssertEqual(current.dependencies, ["cmake"], "\(scenario), after=\(after): current projection includes a build dependency of a kept Formula")
        let proposal = try run(scenario, afterSelection: after, proposed: true)
        XCTAssertEqual(proposal.status, 0, proposal.diagnostic)
        XCTAssertEqual(proposal.dependencies, [], "\(scenario), after=\(after)")
      }
    }
  }

  func testSafetyPassRepeatsForDependenciesOfNewlyKeptCandidates() throws {
    for after in [false, true] {
      XCTAssertEqual(try run("chain", afterSelection: after).dependencies, ["cmake", "mid"])
      XCTAssertEqual(try run("chain", afterSelection: after, proposed: true).dependencies, [])
    }
  }

  func testExistingRuntimeProtectionAndOrdinaryRemovalRemainUnchanged() throws {
    for (scenario, expected) in [("runtime", [String]()), ("bottle", ["cmake"]), ("unused", ["bar", "cmake"])] {
      for after in [false, true] {
        for proposed in [false, true] {
          let result = try run(scenario, afterSelection: after, proposed: proposed)
          XCTAssertEqual(result.status, 0, result.diagnostic)
          XCTAssertEqual(result.dependencies, expected, "\(scenario), after=\(after), proposed=\(proposed)")
        }
      }
    }
  }

  func testExplicitlySelectedFormulaIsNotTreatedAsKept() throws {
    for after in [false, true] {
      let result = try run("selected-formula", afterSelection: after, proposed: true)
      XCTAssertEqual(result.status, 0, result.diagnostic)
      XCTAssertEqual(result.dependencies, ["cmake"])
    }
  }

  func testSafetyPassMustSeeFinalScopeAfterReceiptFilteringKeepsAFormula() throws {
    let initial = try run("unused", afterSelection: true, proposed: true)
    XCTAssertEqual(initial.status, 0, initial.diagnostic)
    XCTAssertEqual(initial.dependencies, ["bar", "cmake"])
    // Execution currently drops changed receipts *after* projecting eligibility.
    // If bar is then kept, filtering that result alone still leaves cmake.
    XCTAssertEqual(initial.dependencies?.filter { $0 != "bar" }, ["cmake"])
    let final = try run("unused", afterSelection: true, proposed: true, scope: ["cmake"])
    XCTAssertEqual(final.status, 0, final.diagnostic)
    XCTAssertEqual(final.dependencies, [], "Recompute against the actual final removal set")
  }

  func testUnavailableSafetyAPIDoesNotFallBackToUnsafeCandidates() throws {
    let result = try run("cask-kept", proposed: true, capability: "missing")
    XCTAssertEqual(result.status, 0, result.diagnostic)
    XCTAssertEqual(result.dependencies, [])
  }

  func testSafetyAPIExecutionFailureDoesNotReturnCandidates() throws {
    let result = try run("cask-kept", proposed: true, capability: "broken")
    XCTAssertNotEqual(result.status, 0)
    XCTAssertNil(result.dependencies)
    XCTAssertTrue(result.diagnostic.contains("fixture safety API failure"))
  }
}
