import Cocoa
import XCTest
@testable import BrewPeek

/// Native lifecycle fixture: every command, snapshot and lock stays below a disposable directory.
final class BackgroundSecurityFixture {
  let workspace: SecurityWorkspace
  let brew: String
  let app: DesktopApp
  var snapshot: Record
  init() throws {
    _ = NSApplication.shared
    let w = try SecurityWorkspace(); workspace = w
    try w.write("brew-background",#"""
      #!/bin/sh
      cd "${0%/*}" || exit 97
      printf '%s\n' "$*" >> commands
      case "$1" in
        help)
          if test -f broken; then exit 2; fi
          if test -f unsupported; then echo 'Unknown command: vulns' >&2; exit 1; fi
          echo 'Output --json findings and scan'; echo 'coverage as JSON' ;;
        vulns)
          touch scan-started
          if test -f cancellable; then exec /bin/sleep 3; fi
          while test -f delayed && test ! -f release; do /bin/sleep 0.02; done
          echo '{"findings":[],"checked":1,"complete":true,"skipped_formulae":[],"outdated_without_sbom":[],"unscanned_formulae":{}}' ;;
        update) : ;;
        outdated) echo '{"formulae":[{"name":"alpha","current_version":"2"}],"casks":[]}' ;;
        info) echo '{"formulae":[{"name":"alpha","installed":[{"version":"1"}]}],"casks":[]}' ;;
        leaves|tap) : ;;
        --prefix|--cellar|--caskroom) echo "$PWD/missing" ;;
        --version) echo 'Homebrew fixture' ;;
        *) exit 99 ;;
      esac
      """#)
    brew = w.root.appendingPathComponent("brew-background").path
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:brew)
    snapshot = try Inventory(brew:brew).collect()
    try SecurityFixture.saveSnapshot(snapshot,to:w.inventory)
    app = DesktopApp(output:w.inventory)
    app.recoveryChecked = true
    app.observeSecuritySnapshot(snapshot,at:w.inventory)
  }
  deinit { app.cancelSecurityRefresh() }
  var commands:[String] {
    ((try? String(contentsOf:workspace.root.appendingPathComponent("commands"),encoding:.utf8)) ?? "").split(separator:"\n").map(String.init)
  }
  var scans: Int { commands.filter { $0 == "vulns --json" }.count }
  func remove(_ name:String) throws {
    let path = workspace.root.appendingPathComponent(name)
    if FileManager.default.fileExists(atPath:path.path) { try FileManager.default.removeItem(at:path) }
  }
  func start() {
    app.observeSecuritySnapshot(snapshot,at:workspace.inventory)
    app.startSecurityRefresh(snapshot,using:Inventory(brew:brew),at:workspace.inventory)
  }
  func saved() throws -> Record { try InventoryStore.load(workspace.inventory) }
  func wait(_ condition:()->Bool,file:StaticString = #filePath,line:UInt = #line) throws {
    let deadline = Date().addingTimeInterval(8)
    while !condition() && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    guard condition() else {
      XCTFail("Background callback timed out",file:file,line:line)
      throw InventoryError(message:"Fixture callback timed out")
    }
  }
  func drain(_ seconds:TimeInterval) { RunLoop.current.run(until:Date().addingTimeInterval(seconds)) }
}
