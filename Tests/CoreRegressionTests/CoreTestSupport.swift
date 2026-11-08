import Foundation
import XCTest
@testable import BrewPeek

/// Every command and data write stays in this fixture's disposable directory.
final class CoreWorkspace {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent("brewpeek-core-tests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  }
  deinit { try? FileManager.default.removeItem(at: root) }
  func url(_ name: String) -> URL { root.appendingPathComponent(name) }
  func write(_ name: String, _ text: String) throws {
    try text.write(to: url(name), atomically: true, encoding: .utf8)
  }
  func json(_ name: String, _ value: Any) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url(name))
  }
  func remove(_ name: String) throws {
    if FileManager.default.fileExists(atPath: url(name).path) { try FileManager.default.removeItem(at: url(name)) }
  }
  func executable(_ name: String, _ script: String) throws -> String {
    try write(name, script)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url(name).path)
    return url(name).path
  }
  @discardableResult func brew(_ body: String) throws -> String {
    try executable("brew-fixture", "#!/bin/sh\ncd \"${0%/*}\" || exit 97\nprintf '%s\\n' \"$*\" >> commands\n" + body)
  }
  var commands: [String] {
    ((try? String(contentsOf: url("commands"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
  }
}
