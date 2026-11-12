import Foundation
import XCTest
@testable import BrewPeek

/// Runs the bundled Ruby projection against isolated in-memory Homebrew doubles.
final class RemovalProjectionTests: XCTestCase {
  func testProjectionHonorsSharedPinnedProtectedAndSelectedPackageRules() throws {
    let fixture = #"""
      require "json"
      $LOADED_FEATURES.concat(["cleanup.rb", "cask/caskroom.rb", "utils/autoremove.rb", "installed_dependents.rb"])
      class Formula
        attr_reader :name, :full_name
        def initialize(name, pinned = false); @name = @full_name = name; @pinned = pinned; end
        def pinned?; @pinned; end
        def installed_runtime_formula_dependencies
          case name
          when "unused" then Formula.installed.select { |f| ["child", "shared"].include?(f.name) }
          when "pinned" then Formula.installed.select { |f| f.name == "pinned-child" }
          else []
          end
        end
        def any_installed_keg; self; end
      def installed_kegs; [self]; end
        def self.installed; @items ||= ["unused", "child", "shared", "pinned", "pinned-child", "unrelated"].map { |n| new(n, n == "pinned") }; end
      end
      module Formulary
        def self.factory(name); Formula.installed.find { |f| f.name == name } || raise("missing formula"); end
      end
      module Homebrew
        module EnvConfig
          def self.no_cleanup_formulae; ENV.fetch("PROTECT_UNUSED", ""); end
        end
        class Cleanup
          def self.skip_clean_formula?(f); f.name == "unused"; end
        end
      end
      module Cask
        class Caskroom
          def self.casks; [Struct.new(:full_token, :depends_on).new("sample", Struct.new(:formula).new(["unused", "pinned"]))]; end
        end
      end
      module Utils
        module Autoremove
          def self.formulae_safe_to_remove(removable, installed)
            raise "cleanup exclusion missing from final safety set" unless installed.any? { |f| f.name == "unused" } || !ENV.key?("PROTECT_UNUSED")
            removable
          end
          def self.removable_formulae(formulae, casks)
            raise "selected Cask not excluded" if formulae.any? { |f| f.name == "unused" } && !casks.empty?
            formulae
          end
        end
      end
      module InstalledDependents
        def self.find_some_installed_dependents(kegs, casks: [])
          return nil if kegs.size == 1 && kegs[0].name == "unused"
          [[Formula.installed.find { |f| f.name == "shared" }], ["other-app"]]
        end
      end
      """#
    func run(protect: Bool, type: String = "cask", name: String = "sample") throws -> [String] {
      let encoded = try JSONSerialization.data(withJSONObject: ["type": type, "name": name])
        .base64EncodedString()
      let code =
        fixture + "\n"
        + PackageRemoval.dependencyScript.replacingOccurrences(
          of: "PAYLOAD", with: "\"" + encoded + "\"")
      let process = Process()
      let pipe = Pipe()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
      process.arguments = ["-e", code]
      process.standardOutput = pipe
      if protect {
        process.environment = ProcessInfo.processInfo.environment.merging([
          "PROTECT_UNUSED": "unused"
        ]) { _, new in new }
      }
      try process.run()
      let output = pipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()
      XCTAssertTrue(process.terminationStatus == 0, "projection fixture failed")
      let result = try XCTUnwrap(JSONSerialization.jsonObject(with: output) as? Record)
      return try XCTUnwrap(result["dependencies"] as? [String])
    }
    let projected = try run(protect: false)
    let protected = try run(protect: true)
    XCTAssertTrue(
      projected == ["child", "unused"],
      "exclude shared, pinned, pinned children and unrelated candidates")
    XCTAssertTrue(protected == [], "honor Homebrew cleanup exclusions")
    let formulaDependencies = try run(protect: false, type: "formula", name: "unused")
    XCTAssertTrue(
      formulaDependencies == ["child"],
      "selected Formula is excluded from projected dependent checks")
  }
}
