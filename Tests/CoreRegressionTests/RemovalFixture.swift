import Foundation
@testable import BrewPeek

final class RemovalFixture {
  let workspace: CoreWorkspace
  let removal: PackageRemoval
  let formulaRoot: Bool
  let withDependencies: Bool
  var key: String { formulaRoot ? "formula:vendor/tap/sample-cli":"cask:vendor/tap/sample-app" }
  init(dependencies: Bool = false, formula: Bool = false) throws {
    let w = try CoreWorkspace()
    workspace = w; formulaRoot = formula; withDependencies = dependencies || formula
    let root = formula ? Self.rootFormula():Self.cask(dependencies: dependencies)
    try w.json("before.json",["formulae":formula ? [root,Self.dependency()]:(dependencies ? [Self.dependency()]:[]),"casks":formula ? []:[root]])
    try w.json("middle.json",["formulae":withDependencies ? [Self.dependency()]:[],"casks":[]])
    try w.json("after.json",["formulae":[],"casks":[]])
    try w.json("before-plan.json",["dependencies":withDependencies ? ["unused"]:[],"blocked":[]])
    try w.json("after-plan.json",["dependencies":withDependencies ? ["unused","unrelated"]:[],"blocked":[]])
    try w.write("status","0")
    let rootCheck = formula ? "test \"$3\" = vendor/tap/sample-cli":"test \"$2\" = --cask"
    let body = #"""
      case "$1" in
        --caskroom) pwd ;;
        info) if test -f formula-done; then cat after.json; elif test -f done; then cat middle.json; else cat before.json; fi ;;
        ruby) test "$HOMEBREW_DEV_CMD_RUN" = 1 || exit 98
          if test -f done; then cat after-plan.json; else cat before-plan.json; fi ;;
        uninstall) test "$HOMEBREW_NO_AUTOREMOVE" = 1 || exit 98
          if ROOT_CHECK; then touch done; else touch formula-done; fi
          echo '==> Removing fixture'; exit "$(cat status)" ;;
        *) exit 99 ;;
      esac
      """#.replacingOccurrences(of:"ROOT_CHECK",with:rootCheck)
    removal = PackageRemoval(brew:try w.brew(body))
  }
  static func dependency(version: String = "1", receipt: Int = 1) -> Record {
    ["name":"unused","full_name":"unused","versions":["stable":"1"],"installed":[["version":version,"time":receipt]],"dependencies":[],"blocked":[]]
  }
  static func rootFormula(requested: Bool = true) -> Record {
    ["name":"sample-cli","full_name":"vendor/tap/sample-cli","versions":["stable":"1"],"installed":[["version":"1","time":1,"installed_on_request":requested]],"dependencies":["unused"]]
  }
  static func cask(version: String = "1.0", receipt: Int = 1, dependencies: Bool = false) -> Record {
    var value: Record = ["token":"sample-app","full_token":"vendor/tap/sample-app","version":version,"installed":version,"installed_time":receipt,"artifacts":[["app":["Sample.app"]]]]
    if dependencies { value["depends_on"] = ["formula":["unused"]] }
    return value
  }
}
