import XCTest
@testable import BrewPeek

final class PackageNoteRenameTests: XCTestCase {
  func testCollectionConfirmsSameTapRenamesAndPreservesOriginalNotes() throws {
    let w = try CoreWorkspace(), notes = PackageNotes(file: w.url("notes.json"))
    let info: Record = [
      "formulae": [
        ["name":"new", "full_name":"a/tools/new", "tap":"a/tools",
         "oldnames":["old","from-elsewhere","still-here","b/tools/other"], "installed":[["version":"1"]]],
        ["name":"still-here", "full_name":"a/tools/still-here", "tap":"a/tools", "installed":[["version":"1"]]]
      ],
      "casks": [["token":"docker-desktop","full_token":"docker-desktop","tap":"homebrew/cask",
                 "old_tokens":["docker"],"installed":"1"]]
    ]
    try w.write("taps.rb", """
      class Tap
        def self.fetch(name)
          raise "unexpected tap" unless ["a/tools","homebrew/cask"].include?(name)
          new
        end
        def installed?; true; end
        def formula_renames; {"old"=>"new","still-here"=>"new"}; end
        def cask_renames; {"docker"=>"docker-desktop"}; end
      end
      """)
    let brew = try w.brew(#"""
      case "$1" in
        ruby) test ! -f unavailable || exit 1; exec /usr/bin/ruby -r ./taps.rb -e "$3" ;;
        outdated) echo '{"formulae":[],"casks":[]}' ;;
        leaves|tap) : ;;
        --prefix|--cellar|--caskroom) echo "$PWD/missing" ;;
        --version) echo fixture ;;
        *) exit 99 ;;
      esac
      """#)
    let inventory = Inventory(brew: brew)
    let data = ["formula:a/tools/old":"previous", "formula:a/tools/new":"current",
                "formula:a/tools/from-elsewhere":"migration", "formula:a/tools/still-here":"installed",
                "formula:b/tools/old":"different tap", "formula:docker":"CLI", "cask:docker":"Desktop"]
    let installed = try Inventory.validateInstalledInfo(info)
    XCTAssertTrue(inventory.formerNoteIDs(in: installed, notesFile: notes.file).isEmpty)
    XCTAssertTrue(w.commands.isEmpty)
    for (id, text) in data { _ = try notes.save(id: id, text: text) }
    let snapshot = try inventory.collect(refreshMetadata: false, installedInfo: info, notesFile: notes.file)
    let formulae = try XCTUnwrap(snapshot["formulae"] as? [Record]), casks = try XCTUnwrap(snapshot["casks"] as? [Record])
    XCTAssertEqual(formulae[0]["formerNoteIDs"] as? [String], ["formula:a/tools/old"])
    XCTAssertNil(formulae[1]["formerNoteIDs"])
    XCTAssertEqual(casks[0]["formerNoteIDs"] as? [String], ["cask:docker"])
    XCTAssertEqual(w.commands.filter { $0.hasPrefix("ruby -e") }.count, 1)
    try w.write("unavailable", "")
    XCTAssertTrue(inventory.formerNoteIDs(in: installed, notesFile: notes.file).isEmpty)
    XCTAssertEqual(try notes.read(), data)
  }
}
