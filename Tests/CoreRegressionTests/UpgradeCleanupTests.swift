import Foundation
import XCTest
@testable import BrewPeek

final class UpgradeCleanupTests: XCTestCase {
  private func formula(_ name:String,_ receipts:[(String,Int)])->Record {
    ["name":name,"full_name":name,"versions":["stable":"3"],"installed":receipts.map { ["version":$0.0,"time":$0.1] as Record }]
  }
  private func setup(_ w:CoreWorkspace, heading:Bool) throws -> Upgrade {
    let activity = heading ? "echo '==> Installing dependencies for target: related'" : "echo '==> Upgrading target'; echo '🍺 target'; echo '==> Running `brew cleanup related`...'"
    let brew = try w.brew("case \"$1\" in\ninfo) if test -f done; then cat after.json; else cat before.json; fi ;;\nupgrade) " + activity + "; touch done ;;\n*) exit 99 ;;\nesac\n")
    try w.json("before.json",["formulae":[formula("target",[("1",1)]),formula("related",[("2",2),("1",1)])],"casks":[]])
    return Upgrade(brew:brew)
  }

  func testIncidentalCleanupDoesNotCountAsUpdateButReinstallStillDoes() throws {
    for (label,retained,count) in [
      ("cleanup only",[("2",2)],1), ("same-version reinstall",[("2",3)],2),
      ("upgrade",[("3",3)],2), ("unchanged",[("2",2),("1",1)],1), ("reordered",[("1",1),("2",2)],1),
    ] {
      let w = try CoreWorkspace(), engine = try setup(w,heading:false)
      try w.json("after.json",["formulae":[formula("target",[("3",3)]),formula("related",retained)],"casks":[]])
      let target = try XCTUnwrap(engine.installed().first { $0.name == "target" })
      let rows = try XCTUnwrap(engine.execute(UpgradePlan(selected:[target],packages:[target],excluded:[])) { _ in }["packages"] as? [Record])
      XCTAssertEqual(rows.count,count,label)
      XCTAssertTrue(rows.allSatisfy { $0["outcome"] as? String == "updated" },label)
    }
  }

  func testDiscoveredDependencyCleanupIsExcludedWithoutLosingReinstalls() throws {
    for (retained,count) in [([("2",2)],1),([("2",3)],2)] {
      let w = try CoreWorkspace(), engine = try setup(w,heading:true)
      try w.json("after.json",["formulae":[formula("target",[("3",3)]),formula("related",retained)],"casks":[]])
      let target = try XCTUnwrap(engine.installed().first { $0.name == "target" })
      let rows = try XCTUnwrap(engine.execute(UpgradePlan(selected:[target],packages:[target],excluded:[])) { _ in }["packages"] as? [Record])
      XCTAssertEqual(rows.count,count)
      XCTAssertTrue(rows.allSatisfy { $0["outcome"] as? String == "updated" })
    }
  }

  func testPlannedCleanupOnlyPackageNeedsAttentionInsteadOfUpdated() throws {
    let w = try CoreWorkspace(), engine = try setup(w,heading:true)
    try w.json("after.json",["formulae":[formula("target",[("3",3)]),formula("related",[("2",2)])],"casks":[]])
    let installed = try engine.installed()
    let target = try XCTUnwrap(installed.first { $0.name == "target" }), old = try XCTUnwrap(installed.first { $0.name == "related" })
    let related = UpgradePackage(name:old.name,fullName:old.fullName,type:old.type,current:old.current,next:"2",receipt:old.receipt,apps:[],reason:"Dependency",installationReceipts:old.installationReceipts)
    let rows = try XCTUnwrap(engine.execute(UpgradePlan(selected:[target],packages:[target,related],excluded:[])) { _ in }["packages"] as? [Record])
    XCTAssertEqual(rows.first { $0["name"] as? String == "related" }?["outcome"] as? String,"attention")
  }
}
