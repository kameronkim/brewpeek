import Foundation
import XCTest
@testable import BrewPeek

final class HomebrewTrustSourceTests: XCTestCase {
  private func command(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe; process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  private func ruby() throws -> String {
    let supplied = ProcessInfo.processInfo.environment["BREWPEEK_TEST_RUBY"]
    let candidates = supplied.map { [$0] } ?? [
      "/opt/homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby",
      "/usr/local/Homebrew/Library/Homebrew/vendor/portable-ruby/current/bin/ruby",
      "/opt/homebrew/opt/ruby/bin/ruby", "/usr/local/opt/ruby/bin/ruby", "/usr/bin/ruby"
    ]
    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
      let result = try command(path, ["-e", "exit((RUBY_VERSION.split('.').first(2).map(&:to_i) <=> [3,4]) >= 0 ? 0 : 1)"])
      if result.status == 0 { return path }
    }
    if supplied != nil {
      XCTFail("BREWPEEK_TEST_RUBY must point to an executable Ruby >= 3.4")
      throw InventoryError(message: "Unsupported explicit test Ruby")
    }
    throw XCTSkip("Official Homebrew trust source requires Ruby >= 3.4; set BREWPEEK_TEST_RUBY to run this contract check")
  }

  func testOfficialSourcePreservesPreviewAndCancelTrustAndSeparatesApproval() throws {
    let runtime = try ruby()
    let workspace = try SecurityWorkspace()
    let folder = "Fixtures/HomebrewTrust"
    let source = try XCTUnwrap(Bundle.module.url(forResource: "trust", withExtension: "rb", subdirectory: folder))
    let checks = try XCTUnwrap(Bundle.module.url(forResource: "source_checks", withExtension: "rb", subdirectory: folder))
    let projection = workspace.root.appendingPathComponent("trust-projection.rb")
    try UpgradeTrust.script.write(to: projection, atomically: true, encoding: .utf8)
    let result = try command(runtime, [checks.path, source.path, projection.path, workspace.root.path])
    guard result.status == 0 else {
      XCTFail(result.output)
      throw InventoryError(message: "Official trust source check failed")
    }
    for type in ["formula", "cask"] {
      for state in ["official", "tap", "package", "untrusted"] {
        XCTAssertTrue(result.output.contains("PASS official trust.rb \(type)/\(state):"), "\(type)/\(state): \(result.output)")
      }
    }
    XCTAssertTrue(result.output.contains("PASS old fully-qualified argument reproduces implicit writes"), result.output)
  }
}
