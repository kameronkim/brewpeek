import Foundation
import XCTest
@testable import BrewPeek

enum DependencyHeadings {
  static let cases: [(String, String, [String])] = [
      ("==> Installing ffmpeg dependency: sdl3", "ffmpeg", ["sdl3"]),
      ("==> Installing ffmpeg dependency: sdl3 (3.2.0)", "ffmpeg", ["sdl3"]),
      ("Upgrading ffmpeg dependency: python@3.14 (3.14.3 -> 3.14.8)", "ffmpeg", ["python@3.14"]),
      ("Upgrading ffmpeg dependency: python@3.14", "ffmpeg", ["python@3.14"]),
      ("Installing vendor/media/ffmpeg dependency: vendor/libs/sdl3 (3.2.0_1)", "vendor/media/ffmpeg", ["vendor/libs/sdl3"]),
      ("Upgrading vendor/media/ffmpeg dependency: vendor/lang/python@3.14 (3.14.3 → 3.14.8)", "vendor/media/ffmpeg", ["vendor/lang/python@3.14"]),
      ("Installing dependencies for ffmpeg: sdl3, python@3.14 and xz", "ffmpeg", ["sdl3", "python@3.14", "xz"]),
      ("Installing dependencies for ffmpeg: sdl3 ↑, python@3.14 ↑ and xz", "ffmpeg", ["sdl3", "python@3.14", "xz"]),
      ("Installing dependencies for ffmpeg: sdl3 ✔, python@3.14 (upgradable), and xz", "ffmpeg", ["sdl3", "python@3.14", "xz"]),
      ("Installing dependencies for vendor/media/ffmpeg: vendor/libs/sdl3 and vendor/lang/python@3.14", "vendor/media/ffmpeg", ["vendor/libs/sdl3", "vendor/lang/python@3.14"]),
      ("Installing dependencies for ffmpeg: sdl3 (3.2.0) and python@3.14 (3.14.3 -> 3.14.8)", "ffmpeg", ["sdl3", "python@3.14"]),
      ("Installing dependencies for ffmpeg: sdl3, python@3.14, xz", "ffmpeg", ["sdl3", "python@3.14", "xz"]),
      ("Installing dependencies for ffmpeg: homebrew/core/sdl3 and sdl3", "ffmpeg", ["homebrew/core/sdl3"]),
      ("\u{1b}[1m==> Installing ffmpeg dependency: \u{1b}[32msdl3\u{1b}[0m (3.2.0)", "ffmpeg", ["sdl3"]),
    ]
}

final class DependencyLogFixture {
  let workspace: CoreWorkspace
  let brew: String
  var before: [Record] { [Self.formula("ffmpeg","1"),Self.formula("vendor/media/ffmpeg","1"),Self.formula("vendor/libs/sdl3","1")] }
  static func formula(_ name:String,_ version:String)->Record {
    ["name":name.split(separator:"/").last.map(String.init) ?? name,"full_name":name,"versions":["stable":"2"],"dependencies":[String](),"installed":[["version":version,"time":version == "1" ? 1:2]]]
  }
  init() throws {
    let w = try CoreWorkspace(); workspace = w
    brew = try w.brew(#"""
      case "$1" in
        --caskroom) pwd ;;
        info) if test -f completed; then cat after.json; else cat before.json; fi ;;
        upgrade) cat activity; touch completed; exit "$(cat status)" ;;
        *) exit 99 ;;
      esac
      """#)
  }
  func run(_ lines:[String],parent:String = "ffmpeg",after:[Record],status:String = "0",includeAll:Bool = false) throws -> ([Record],Record) {
    try workspace.remove("completed")
    try workspace.json("before.json",["formulae":before,"casks":[["token":"ffmpeg","installed":"1"]]])
    try workspace.json("after.json",["formulae":after,"casks":[["token":"ffmpeg","installed":"1"]]])
    try workspace.write("activity",lines.joined(separator:"\n")+"\n"); try workspace.write("status",status)
    let engine = Upgrade(brew:brew), installed = try engine.installed()
    var selected = try XCTUnwrap(installed.first { $0.id == "formula:"+parent })
    selected.reason = "Selected"
    if selected.fullName.contains("/") { selected.upgradePath = workspace.url("tap/Formula/ffmpeg.rb").path }
    let packages = includeAll ? installed.map { $0.id == selected.id ? selected:$0 }:[selected]
    var events:[Record]=[]
    let result = try engine.execute(UpgradePlan(selected:[selected],packages:packages,excluded:[])) { events.append($0) }
    XCTAssertTrue(workspace.commands.allSatisfy { $0.hasPrefix("info ") || $0.hasPrefix("upgrade ") || $0 == "--caskroom" })
    return (events,result)
  }
  static func activityPackages(_ events:[Record])->[Record] {
    events.last { $0["kind"] as? String == "activity" && $0["packages"] is [Record] }?["packages"] as? [Record] ?? []
  }
}
