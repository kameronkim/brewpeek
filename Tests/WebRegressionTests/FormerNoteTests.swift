import XCTest
@testable import BrewPeek

final class FormerNoteTests: XCTestCase {
  func testFormerAndCurrentNotesStaySearchableAndSeparate() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = PackageNotes(file: dir.appendingPathComponent("notes.json"))
    _ = try store.save(id: "cask:docker", text: "납품 <clip>")
    _ = try store.save(id: "formula:docker", text: "CLI only")
    let page = try WebTestPage(notesDirectory: dir)
    try page.run("""
      const app={id:'cask:docker-desktop',name:'docker-desktop',type:'cask',apps:[],version:'1',formerNoteIDs:['cask:docker']};
      setInventory({casks:[app],formulae:[],environment:{},taps:[]});
      const wait=async predicate => {
        for(let i=0;i<150;i++){if(predicate()) return;await new Promise(r=>setTimeout(r,15))}
        throw Error('Note did not appear');
      };
      await wait(()=>notesReady);
      const row=()=>document.querySelector('.package-row');
      const search=value=>{$('search').value=value;$('search').dispatchEvent(new Event('input'))};
      search('납품');assert(row().querySelector('.personal-note').textContent==='납품 <clip>', 'Previous note appears on the new package');
      row().querySelector('button').click();
      const details=()=>row().nextElementSibling;
      assert(details().textContent.includes('Saved as docker')&&!details().querySelector('clip'),'Old name and escaped text');
      details().querySelector('[data-note-action="edit"]').click();
      const input=details().querySelector('textarea');assert(input.value==='', 'Current identity has its own editor');
      input.value='Current project';input.dispatchEvent(new Event('input',{bubbles:true}));
      details().querySelector('[data-note-action="save"]').click();
      await wait(()=>row()?.querySelector('.personal-note')?.textContent==='Current project');
      assert(details().textContent.includes('납품 <clip>')&&details().textContent.includes('Current project'),'Both notes remain visible');
      search('CLI only');assert(!row(),'Same-name formula note stays separate');return true;
      """)
    XCTAssertEqual(try store.read(), ["cask:docker":"납품 <clip>", "formula:docker":"CLI only", "cask:docker-desktop":"Current project"])
  }
}
