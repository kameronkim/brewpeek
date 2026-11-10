import Foundation
import XCTest
@testable import BrewPeek

/// Executes the product script against pinned upstream methods and disposable keg/receipt doubles.
final class VersionCleanupTests: XCTestCase {
  private final class Fixture {
    let workspace: CoreWorkspace
    let cleanup: VersionCleanup
    var state: Record
    init(kegs: [Record] = [["version": "0.1"], ["version": "0.2"]],
         latest: String = "0.3", scheme: Int = 0, mode: String = "713") throws {
      let w = try CoreWorkspace(); workspace = w
      state = ["latest": latest, "version_scheme": scheme, "kegs": kegs]
      try FileManager.default.createDirectory(at: w.url("cellar"), withIntermediateDirectories: true)
      for keg in kegs { try Self.createKeg(keg, in: w) }
      try w.json("state.json", state)
      let fixture = try XCTUnwrap(Bundle.module.url(forResource: "projection_fixture", withExtension: "rb", subdirectory: "Fixtures/HomebrewVersionCleanup"))
      try w.write("fixture-path", fixture.path)
      try w.write("runtime", ProcessInfo.processInfo.environment["BREWPEEK_TEST_RUBY"] ?? "/usr/bin/ruby")
      try w.write("mode", mode)
      let brew = try w.brew(#"""
        test "$1" = ruby && test "$HOMEBREW_DEV_CMD_RUN" = 1 || exit 99
        exec "$(cat runtime)" "$(cat fixture-path)" "$PWD" "$(cat mode)" "$3"
        """#)
      cleanup = VersionCleanup(brew: brew)
    }
    static func createKeg(_ keg: Record, in workspace: CoreWorkspace) throws {
      let version = try XCTUnwrap(keg["version"] as? String)
      let path = workspace.url("cellar/" + version)
      try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
      if keg["receipt"] as? Bool == false { return }
      if keg["malformed"] as? Bool == true {
        try "not JSON".write(to: path.appendingPathComponent("INSTALL_RECEIPT.json"), atomically: true, encoding: .utf8)
      } else {
        try workspace.json("cellar/" + version + "/INSTALL_RECEIPT.json", ["source": ["versions": ["version_scheme": keg["scheme"] as? Int ?? 0]]])
      }
    }
    func save() throws { try workspace.json("state.json", state) }
    func prepare() throws -> VersionCleanupPlan { try cleanup.prepare(key: "formula:fixture") }
    func upstream() throws -> [String] {
      let text = try cleanup.engine.dependencyProjection(
        #"puts JSON.generate(Formulary.factory("fixture").eligible_kegs_for_cleanup(quiet: true).map { |k| k.version.to_s })"#,
        control: UpgradePreparation())
      return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String])
    }
    var calls: [String] { lines("cleanup-calls") }
    var locks: [String] { lines("locks") }
    private func lines(_ name: String) -> [String] {
      ((try? String(contentsOf: workspace.url(name), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
  }

  func testMissingLatestVersionChangesCandidatesAndConfirmationFingerprint() throws {
    let f = try Fixture(mode: "before")
    XCTAssertEqual(try f.upstream(), [])
    let before = try f.prepare()
    XCTAssertTrue(before.versions.allSatisfy { !$0.removable })
    try f.workspace.write("mode", "713")
    XCTAssertEqual(try f.upstream(), ["0.1"])
    let after = try f.prepare()
    XCTAssertEqual(after.versions.filter(\.removable).map(\.version), ["0.1"])
    XCTAssertNotEqual(before.fingerprint, after.fingerprint)
    let rows = try XCTUnwrap(after.record["packages"] as? [Record])
    XCTAssertEqual(rows.map { $0["availableVersion"] as? String }, ["Remove", "Keep"])
    XCTAssertTrue(f.calls.isEmpty)
  }

  func testLinkedOptlinkedPinnedExcludedAndRequiredKegsAreProtected() throws {
    for kind in ["linked", "optlinked", "pinned", "excluded", "keepme"] {
      let old: Record = ["version": "0.1", "linked": kind == "linked", "optlinked": kind == "optlinked", "keepme": kind == "keepme" ? ["another-keg"] : [String]()]
      let f = try Fixture(kegs: [old, ["version": "0.2"]])
      f.state["pinned"] = kind == "pinned"; f.state["excluded"] = kind == "excluded"
      try f.save()
      XCTAssertEqual(try f.upstream(), ["linked", "keepme"].contains(kind) ? [] : ["0.1"], kind)
      // The app intentionally protects a whole pinned/excluded Formula, and also
      // optlinked kegs; upstream's per-keg check alone can be less restrictive.
      XCTAssertTrue(try f.prepare().versions.allSatisfy { !$0.removable }, kind)
      XCTAssertTrue(f.calls.isEmpty)
    }
  }

  func testVersionSchemeDowngradeAndHeadRulesUseUpstreamEligibility() throws {
    let cases: [([Record], String, Int, [String])] = [
      ([["version": "0.1", "scheme": 1], ["version": "0.2", "scheme": 0]], "0.1.1", 1, ["0.2"]),
      ([["version": "3.6.2"], ["version": "3.6.3"], ["version": "3.6.5"]], "3.5.9", 1, ["3.6.2", "3.6.3"]),
      ([["version": "0.1"], ["version": "0.2"], ["version": "HEAD-111111"], ["version": "HEAD-222222"]], "0.3", 0, ["0.1"]),
      ([["version": "0.2"]], "0.3", 0, [])
    ]
    for (kegs, latest, scheme, expected) in cases {
      let f = try Fixture(kegs: kegs, latest: latest, scheme: scheme)
      XCTAssertEqual(try f.upstream(), expected)
      XCTAssertEqual(try f.prepare().versions.filter(\.removable).map(\.version), expected)
    }
    let head = try Fixture(kegs: [["version": "0.1"], ["version": "0.2"], ["version": "HEAD-111111"], ["version": "HEAD-222222"]], latest: "HEAD-222222")
    head.state["head_spec"] = true; head.state["latest_head"] = "HEAD-222222"; try head.save()
    XCTAssertEqual(Set(try head.prepare().versions.filter(\.removable).map(\.version)), Set(["0.1", "HEAD-111111"]))
  }

  func testMissingReceiptsPreserveHomebrewCandidatesWithoutBlockingPreparation() throws {
    for kegs: [Record] in [
      [["version": "0.1"], ["version": "0.2", "receipt": false]],
      [["version": "0.1"], ["version": "0.2"], ["version": "0.4", "receipt": false]]
    ] {
      let f = try Fixture(kegs: kegs)
      XCTAssertEqual(try f.upstream(), kegs.count == 2 ? [] : ["0.1"])
      let plan = try f.prepare()
      XCTAssertEqual(plan.versions.filter(\.removable).map(\.version), kegs.count == 2 ? [] : ["0.1"])
      let missingVersion = try XCTUnwrap(kegs.last?["version"] as? String)
      let receipt = f.workspace.url("cellar/" + missingVersion + "/INSTALL_RECEIPT.json")
      XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
      if kegs.count == 3 {
        let result = try f.cleanup.execute(plan, selected: ["0.1"]) { _ in }
        XCTAssertEqual((result["packages"] as? [Record])?.first?["outcome"] as? String, "removed")
        XCTAssertEqual(f.calls, ["0.1"])
        XCTAssertEqual(try f.prepare().versions.map(\.version), ["0.2", "0.4"])
      } else {
        XCTAssertTrue(f.calls.isEmpty)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
    }
  }

  func testInvalidReceiptsStillFailClosed() throws {
    let sparse = try Fixture()
    try sparse.workspace.json("cellar/0.1/INSTALL_RECEIPT.json", [String: String]())
    XCTAssertEqual(try sparse.upstream(), ["0.1"], "Homebrew defaults a missing version_scheme to zero")
    XCTAssertEqual(try sparse.prepare().versions.filter(\.removable).map(\.version), ["0.1"])
    let malformed = try Fixture(kegs: [["version": "0.1", "malformed": true], ["version": "0.2"]])
    XCTAssertThrowsError(try malformed.prepare())
    XCTAssertTrue(malformed.calls.isEmpty)
    let unreadable = try Fixture(kegs: [["version": "0.1", "receipt": false], ["version": "0.2"]])
    try FileManager.default.createDirectory(at: unreadable.workspace.url("cellar/0.1/INSTALL_RECEIPT.json"), withIntermediateDirectories: false)
    XCTAssertThrowsError(try unreadable.prepare(), "Non-missing receipt read errors must not use the missing fallback")
    XCTAssertTrue(unreadable.calls.isEmpty)
  }

  func testMissingReceiptCanBeEligibleOnceLatestIsInstalled() throws {
    for protection in ["none", "linked", "optlinked", "pinned"] {
      let f = try Fixture(kegs: [["version": "0.1", "receipt": false,
                                "linked": protection == "linked", "optlinked": protection == "optlinked"],
                               ["version": "0.2"]], latest: "0.2")
      f.state["pinned"] = protection == "pinned"; try f.save()
      XCTAssertEqual(try f.upstream(), protection == "linked" ? [] : ["0.1"], protection)
      let plan = try f.prepare()
      XCTAssertEqual(plan.versions.filter(\.removable).map(\.version), protection == "none" ? ["0.1"] : [], protection)
      if protection == "none" {
        let result = try f.cleanup.execute(plan, selected: ["0.1"]) { _ in }
        XCTAssertEqual((result["packages"] as? [Record])?.first?["outcome"] as? String, "removed")
        XCTAssertEqual(f.calls, ["0.1"])
      } else {
        XCTAssertTrue(f.calls.isEmpty)
      }
      XCTAssertFalse(FileManager.default.fileExists(atPath: f.workspace.url("cellar/0.1/INSTALL_RECEIPT.json").path))
    }
  }

  func testReceiptAppearanceInvalidatesConfirmedMissingReceipt() throws {
    let f = try Fixture(kegs: [["version": "0.1", "receipt": false], ["version": "0.2"]], latest: "0.2")
    let plan = try f.prepare()
    try f.workspace.json("cellar/0.1/INSTALL_RECEIPT.json", [String: String]())
    XCTAssertNotEqual(plan.fingerprint, try f.prepare().fingerprint)
    let result = try f.cleanup.execute(plan, selected: ["0.1"]) { _ in }
    XCTAssertTrue((result["details"] as? String)?.contains("Installed versions changed") == true)
    XCTAssertTrue(f.calls.isEmpty)
    XCTAssertEqual(f.locks, ["lock", "unlock"])
  }

  func testExecutionRemovesOnlySelectedEligibleVersionAndVerifiesResult() throws {
    let f = try Fixture(), plan = try f.prepare()
    XCTAssertThrowsError(try f.cleanup.execute(plan, selected: ["0.2"]) { _ in })
    XCTAssertThrowsError(try f.cleanup.execute(plan, selected: ["0.1", "0.1"]) { _ in })
    let result = try f.cleanup.execute(plan, selected: ["0.1"]) { _ in }
    XCTAssertEqual(result["verified"] as? Bool, true)
    XCTAssertEqual((result["packages"] as? [Record])?.first?["outcome"] as? String, "removed")
    XCTAssertEqual(f.calls, ["0.1"])
    XCTAssertEqual(try f.prepare().versions.map(\.version), ["0.2"])
    XCTAssertEqual(f.locks, ["lock", "unlock"])
  }

  func testRecheckRejectsChangedReceiptLinkPinSchemeOrInstalledSet() throws {
    for change in ["receipt", "linked", "optlinked", "pinned", "scheme", "installed"] {
      let f = try Fixture(), plan = try f.prepare()
      var kegs = try XCTUnwrap(f.state["kegs"] as? [Record])
      switch change {
      case "receipt": try f.workspace.write("cellar/0.1/INSTALL_RECEIPT.json", "{\"time\":2}")
      case "linked", "optlinked": kegs[0][change] = true
      case "pinned": f.state["pinned"] = true
      case "scheme": try f.workspace.json("cellar/0.1/INSTALL_RECEIPT.json", ["source": ["versions": ["version_scheme": 2]]])
      default:
        let keg: Record = ["version": "0.3"]
        kegs.append(keg); try Fixture.createKeg(keg, in: f.workspace)
      }
      f.state["kegs"] = kegs; try f.save()
      let result = try f.cleanup.execute(plan, selected: ["0.1"]) { _ in }
      XCTAssertNotEqual(result["exitCode"] as? Int32, 0, change)
      XCTAssertTrue((result["details"] as? String)?.contains("Installed versions changed") == true, change)
      XCTAssertTrue(f.calls.isEmpty, change)
      XCTAssertEqual(f.locks, ["lock", "unlock"], change)
    }
  }

  func testReceiptDisappearanceAndCleanupFailureNeverReportRemoval() throws {
    for disappear in [true, false] {
      let f = try Fixture(), plan = try f.prepare()
      if disappear {
        try FileManager.default.removeItem(at: f.workspace.url("cellar/0.1/INSTALL_RECEIPT.json"))
      } else {
        var kegs = try XCTUnwrap(f.state["kegs"] as? [Record]); kegs[0]["cleanup_error"] = true
        f.state["kegs"] = kegs; try f.save()
      }
      let result = try f.cleanup.execute(plan, selected: ["0.1"]) { _ in }
      XCTAssertEqual((result["packages"] as? [Record])?.first?["outcome"] as? String, "attention")
      XCTAssertEqual(f.calls, disappear ? [] : ["0.1"])
      XCTAssertEqual(f.locks, ["lock", "unlock"])
    }
  }
}
