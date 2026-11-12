import Foundation
import XCTest
@testable import BrewPeek

/// Migrated from DependencyLogChecks without using log output as installation proof.
final class DependencyLogTests: XCTestCase {
  func testSupportedHeadingFormatsPreserveParentsAndCanonicalNames() throws {
    for (line,parent,names) in DependencyHeadings.cases {
      let parsed = try XCTUnwrap(HomebrewDependencyHeading.parse(line),line)
      XCTAssertEqual(parsed.parent,parent,line); XCTAssertEqual(parsed.names,names,line)
    }
  }

  func testMalformedAndUnrelatedLinesDoNotCreateDependencies() {
    for line in ["==> Upgrading ffmpeg","Downloading sdl3","Warning: Installing ffmpeg dependency: sdl3","Installing ffmpeg dependency: sdl3;rm","Installing ffmpeg dependency: ../sdl3","Installing ffmpeg dependency: sdl3 extra-text","Installing bad parent dependency: sdl3","Installing dependencies for ffmpeg:","Installing ffmpeg dependency: sdl3 (unterminated"] {
      XCTAssertNil(HomebrewDependencyHeading.parse(line),line)
    }
  }

  func testEverySupportedHeadingThroughExecutionDiscoversDirectRelationships() throws {
    let f = try DependencyLogFixture()
    for (line,_,names) in DependencyHeadings.cases {
      let parent = line.contains("vendor/media/ffmpeg") ? "vendor/media/ffmpeg":"ffmpeg"
      let after = f.before.map { ($0["full_name"] as? String) == parent ? DependencyLogFixture.formula(parent,"2"):$0 }
        + names.filter { $0 != "vendor/libs/sdl3" }.map { DependencyLogFixture.formula(HomebrewPackageName.formulaIdentity($0),"2") }
      let (events,result) = try f.run([line],parent:parent,after:after)
      let items = DependencyLogFixture.activityPackages(events)
      for name in names {
        let item = try XCTUnwrap(items.first { $0["id"] as? String == "formula:"+HomebrewPackageName.formulaIdentity(name) },line)
        XCTAssertEqual(item["relationship"] as? String,"Required by "+parent,line)
      }
      XCTAssertEqual(result["verified"] as? Bool,true)
    }
  }

  func testSameNameTapAndCaskProgressIsNotGuessedFromBareNames() throws {
    let f = try DependencyLogFixture()
    let (collision,_) = try f.run(["Installing ffmpeg dependency: sdl3 (2.0)"],after:f.before+[DependencyLogFixture.formula("sdl3","2")],includeAll:true)
    let states = collision.compactMap { $0["states"] as? [String:String] }.last ?? [:]
    XCTAssertEqual(states["formula:vendor/libs/sdl3"],"Waiting for Homebrew")
    XCTAssertEqual(states["cask:ffmpeg"],"Waiting for Homebrew")
    let (qualified,_) = try f.run(["Installing vendor/media/ffmpeg dependency: vendor/libs/sdl3 (1 -> 2)"],after:f.before,includeAll:true)
    XCTAssertEqual(qualified.compactMap { $0["states"] as? [String:String] }.last?["formula:ffmpeg"],"Waiting for Homebrew")
    let (ambiguous,_) = try f.run(["Downloading ffmpeg"],after:f.before,includeAll:true)
    XCTAssertFalse(ambiguous.compactMap { $0["states"] as? [String:String] }.contains { $0["cask:ffmpeg"] == "Downloading…" })
  }

  func testRepeatedHeadingsDoNotDuplicateDependenciesOrAttachWrongParent() throws {
    let f = try DependencyLogFixture()
    let repeated = ["Installing dependencies for vendor/media/ffmpeg: vendor/libs/sdl3 and python@3.14","Upgrading vendor/media/ffmpeg dependency: vendor/libs/sdl3 (1 -> 2)","Installing vendor/media/ffmpeg dependency: python@3.14 (3.14.8)"]
    let (events,_) = try f.run(repeated,parent:"vendor/media/ffmpeg",after:f.before,includeAll:true)
    let items = DependencyLogFixture.activityPackages(events)
    XCTAssertEqual(items.filter { $0["id"] as? String == "formula:vendor/libs/sdl3" }.count,1)
    XCTAssertEqual(items.first { $0["id"] as? String == "formula:python@3.14" }?["relationship"] as? String,"Required by vendor/media/ffmpeg")
    let (sameName,_) = try f.run(["Installing ffmpeg dependency: cask-safe (1.0)"],after:f.before,includeAll:true)
    XCTAssertEqual(DependencyLogFixture.activityPackages(sameName).first { $0["name"] as? String == "cask-safe" }?["relationship"] as? String,"Required by ffmpeg (formula)")
    XCTAssertTrue(try Upgrade(brew:f.brew).installed().contains { $0.id == "cask:ffmpeg" })
    let (unknownParent,_) = try f.run(["Installing vendor/media/ffmpeg dependency: newdep (1.0)"],parent:"ffmpeg",after:f.before)
    XCTAssertEqual(DependencyLogFixture.activityPackages(unknownParent).first { $0["name"] as? String == "newdep" }?["relationship"] as? String,"")
  }

  func testSuccessLookingLogsAndVersionAnnotationsCannotOverrideMetadata() throws {
    let f = try DependencyLogFixture()
    for exit in ["0","1"] {
      let (_,result) = try f.run(["Installing ffmpeg dependency: ghost (9.0)","🍺 ghost installed successfully"],after:f.before,status:exit)
      let ghost = try XCTUnwrap((result["packages"] as? [Record])?.first { $0["name"] as? String == "ghost" })
      XCTAssertFalse(["installed","updated"].contains(ghost["outcome"] as? String ?? ""))
      XCTAssertEqual(ghost["actualVersion"] as? String,"Not installed")
    }
    let (_,positive) = try f.run(["Installing ffmpeg dependency: sdl3 (9.9.9)"],after:f.before+[DependencyLogFixture.formula("sdl3","2")])
    let item = try XCTUnwrap((positive["packages"] as? [Record])?.first { $0["name"] as? String == "sdl3" })
    XCTAssertEqual(item["outcome"] as? String,"installed"); XCTAssertEqual(item["actualVersion"] as? String,"2")
  }
}
