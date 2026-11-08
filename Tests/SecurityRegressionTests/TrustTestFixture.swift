import Cocoa
import XCTest
@testable import BrewPeek

/// Uses the real native approval flow with a file-backed Homebrew double and injected output path.
final class TrustTestFixture {
  let workspace: SecurityWorkspace
  let brew: String
  let keys: [String]
  let app: DesktopApp
  init(formulaeOnly: Bool = false, state: String = "untrusted") throws {
    _ = NSApplication.shared
    let w = try SecurityWorkspace(); workspace = w
    let packages: [Record] = formulaeOnly
      ? [["type":"formula","name":"alpha","full":"vendor/tools/alpha"],["type":"formula","name":"beta","full":"vendor/tools/beta"]]
      : [["type":"formula","name":"alpha","full":"vendor/tools/alpha"],["type":"cask","name":"app","full":"vendor/tools/app"]]
    keys = try packages.map { try XCTUnwrap($0["type"] as? String)+":"+XCTUnwrap($0["full"] as? String) }
    try w.write("brew-trust",SecurityFixture.text("trust-brew",extension:"py"))
    brew = w.root.appendingPathComponent("brew-trust").path
    try FileManager.default.setAttributes([.posixPermissions:0o700],ofItemAtPath:brew)
    try JSONSerialization.data(withJSONObject:packages).write(to:w.root.appendingPathComponent("packages"))
    try w.write("states",String(decoding:JSONSerialization.data(withJSONObject:Dictionary(uniqueKeysWithValues:keys.map { ($0,state) })),as:UTF8.self))
    try w.write("reference","vendor/tools")
    app = DesktopApp(output:w.inventory); app.recoveryChecked = true
  }
  deinit { app.cancelSecurityRefresh(); app.operation.control?.cancelAndWait() }
  func setStates(_ state:String) throws {
    try workspace.write("states",String(decoding:JSONSerialization.data(withJSONObject:Dictionary(uniqueKeysWithValues:keys.map { ($0,state) })),as:UTF8.self))
  }
  var commands:[[String]] {
    let log = (try? String(contentsOf:workspace.root.appendingPathComponent("commands"),encoding:.utf8)) ?? ""
    return log.split(separator:"\n").compactMap { try? JSONSerialization.jsonObject(with:Data($0.utf8)) as? [String] }
  }
  var writes:[String] {
    ((try? String(contentsOf:workspace.root.appendingPathComponent("explicit-writes"),encoding:.utf8)) ?? "").split(separator:"\n").map(String.init)
  }
  var scans:Int { commands.filter { $0 == ["vulns","--json"] }.count }
  func requiredPlan() throws -> UpgradeTrustPlan {
    do { _ = try Upgrade(brew:brew).prepare(keys:keys) }
    catch let required as UpgradeTrustRequired { return required.plan }
    XCTFail("An untrusted fixture must require explicit consent")
    throw InventoryError(message:"Expected trust confirmation")
  }
  func approve(_ plan:UpgradeTrustPlan,request:String = "approved") {
    app.operation.plan = .trust(plan)
    app.handleUpdate(["action":"startTrust","token":plan.token,"requestID":request])
  }
  func wait(_ condition:()->Bool,file:StaticString = #filePath,line:UInt = #line) throws {
    try NativeTestWait.until(condition, file: file, line: line)
  }
}
