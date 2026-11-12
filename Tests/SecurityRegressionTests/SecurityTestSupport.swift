import Foundation
import XCTest
@testable import BrewPeek

enum SecurityFixture {
  static func text(_ name: String, extension suffix: String = "json") throws -> String {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: suffix, subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
  }

  static func report(_ name: String) throws -> Record {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text(name).utf8)) as? Record)
  }

  static func result(_ name: String, status: Int32 = 0, exited: Bool = true) throws -> Inventory.CommandResult {
    .init(output: try text(name), error: "Fixture diagnostic", status: status, exited: exited)
  }

  static func check(_ name: String, status: Int32 = 0) throws -> Record {
    FormulaSecurity.interpret(try result(name, status: status))
  }

  static func snapshot(id: String = "snapshot-A", check: Record? = nil) -> Record {
    var value: Record = [
      "snapshotID": id, "formulae": [Record](), "casks": [Record](), "taps": [String](),
      "environment": ["updated": "fixture"], "testMetadata": ["preserve": "original"],
    ]
    value["securityCheck"] = check
    return value
  }

  // Production creates the operation lock while generating the initial inventory.
  static func saveSnapshot(_ value: Record, to destination: URL) throws {
    try HomebrewOperationLock.withLock(at: destination) {
      try InventoryStore.save(value, to: destination)
    }
  }

  static func canonical(_ value: Record) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
  }
}

final class SecurityWorkspace {
  let root: URL
  var inventory: URL { root.appendingPathComponent("inventory.json") }
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("brewpeek-security-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }
  deinit { try? FileManager.default.removeItem(at: root) }
  func write(_ name: String, _ text: String) throws {
    try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
  }
}

/// All child commands are an allowlisted local shell fixture, never the user's Homebrew.
final class SecurityCommandFixture {
  let workspace: SecurityWorkspace
  var brew: String { workspace.root.appendingPathComponent("brew-fixture").path }
  init(report: String = "complete-open", status: Int32 = 1) throws {
    workspace = try SecurityWorkspace()
    try workspace.write("report.json", SecurityFixture.text(report))
    try workspace.write("status", String(status))
    try workspace.write("help.txt", "Output --json findings and scan coverage\n")
    try workspace.write("help-status", "0")
    try workspace.write("stderr.txt", SecurityFixture.text("command-failure", extension: "txt"))
    try workspace.write("brew-fixture", #"""
      #!/bin/sh
      cd "${0%/*}" || exit 97
      printf '%s\n' "$*" >> commands
      case "$*" in
        'help vulns') /bin/cat help.txt; exit "$(/bin/cat help-status)" ;;
        'vulns --json')
          if [ -f slow ]; then exec /bin/sleep 2; fi
          /bin/cp report.json captured.json
          /usr/bin/touch scan-started
          while [ -f delayed ] && [ ! -f release ]; do /bin/sleep 0.02; done
          /bin/cat captured.json
          /bin/cat stderr.txt >&2
          exit "$(/bin/cat status)" ;;
        *) exit 98 ;;
      esac
      """#)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brew)
  }
  var commands: [String] {
    ((try? String(contentsOf: workspace.root.appendingPathComponent("commands"), encoding: .utf8)) ?? "")
      .split(separator: "\n").map(String.init)
  }
}
