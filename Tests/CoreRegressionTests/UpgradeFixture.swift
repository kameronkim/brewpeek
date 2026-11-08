import Foundation
@testable import BrewPeek

final class UpgradeFixture {
  let workspace: CoreWorkspace
  let engine: Upgrade
  init() throws {
    let w = try CoreWorkspace()
    workspace = w
    try w.json("before.json", Self.info("1.0", false))
    try w.json("after.json", Self.info("2.0", true, true))
    try w.write("plan", "==> Would upgrade 1 requested outdated package\nnode 1.0 -> 2.0 (1MB)\n==> Would install 1 dependency\nssl 3.0\n")
    let brew = try w.brew(#"""
      case "$1" in
        --caskroom) pwd ;;
        info) if test -f done; then cat after.json; elif test -f targeted; then
          case "$*" in *--installed*) cat before.json ;; *) cat metadata.json ;; esac
          else cat before.json; fi ;;
        upgrade) case "$*" in
          *--dry-run*) cat plan ;;
          *) echo '==> Installing node dependency: extra'; echo '==> Upgrading node'; echo '🍺 node'; touch done; if test -f fail; then exit 1; fi ;;
          esac ;;
        *) exit 99 ;;
      esac
      """#)
    engine = Upgrade(brew: brew)
  }
  static func info(_ version: String, _ dep: Bool, _ extra: Bool = false) -> Record {
    var formulae: [Record] = [
      ["name":"node", "full_name":"node", "versions":["stable":"2.0"], "dependencies":["ssl"],
       "installed":[["version":version,"time":version == "1.0" ? 1 : 2]]],
      ["name":"ssl", "full_name":"ssl", "versions":["stable":"3.0"],
       "installed":dep ? [["version":"3.0","time":2]] : []],
    ]
    if extra { formulae.append(["name":"extra","full_name":"extra","versions":["stable":"4.0"],"installed":[["version":"4.0","time":2]]]) }
    return ["formulae":formulae,"casks":[]]
  }
}
