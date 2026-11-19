import Cocoa
import XCTest
@testable import BrewPeek

final class NotesLibraryTests: XCTestCase {
  func testReportMenuFindsInstalledAndRemovedNotesAndDeletesOnlyTheConfirmedNote() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PackageNotes(file: directory.appendingPathComponent("notes.json"))
    let formula = "formula:vendor/tools/demo", cask = "cask:demo", orphan = "formula:wget"
    _ = try store.save(id: formula, text: "Use for <clips>")
    _ = try store.save(id: cask, text: "Player")
    _ = try store.save(id: orphan, text: "Old downloads")

    let page = try WebTestPage(notesDirectory: directory)
    try page.run("""
      window.until = async condition => {
        for (let i=0; i<200; i++) {
          if (condition()) return;
          await new Promise(resolve => setTimeout(resolve, 10));
        }
        throw Error('Note action timed out');
      };
      window.sample = {formulae:[{id:'formula:vendor/tools/demo', type:'formula', name:'demo', version:'1'}],
        casks:[{id:'cask:demo', type:'cask', name:'demo', version:'1'}], taps:[], environment:{}};
      setInventory(sample); await until(() => notesReady);
      $('search').focus(); return true;
      """)

    let desktop = DesktopApp(output: directory.appendingPathComponent("inventory.json"))
    desktop.web = page.web
    let previousMenu = NSApp.mainMenu
    defer { NSApp.mainMenu = previousMenu }
    desktop.installMenu()
    let item = try XCTUnwrap(NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
      .first { $0.action == #selector(DesktopApp.showPackageNotes) })
    XCTAssertFalse(desktop.validateMenuItem(item))
    desktop.hasDisplayedData = true
    XCTAssertTrue(desktop.validateMenuItem(item))
    XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    try page.run("""
      await until(() => notesDialog.open);
      window.row = id => [...notesList.children].find(li => li.dataset.noteId === id);
      window.filterNotes = value => { notesSearch.value=value; notesSearch.dispatchEvent(new Event('input')); };
      const id='formula:vendor/tools/demo', orphan='formula:wget';
      assert(document.activeElement===notesSearch && notesList.children.length===3,'Menu opens searchable sheet');
      assert(row(id).textContent.includes('vendor/tools/demo') && row(id).textContent.includes('Formula')
        && row('cask:demo').textContent.includes('Cask'),'Tap and type distinguish names');
      assert(row(id).textContent.includes('<clips>') && !notesList.querySelector('clips'),'Literal note text');
      filterNotes('PLAYER'); assert(notesList.children.length===1 && row('cask:demo'),'Find by note text');
      filterNotes('vendor/tools'); assert(notesList.children.length===1 && row(id),'Find by package identity');
      filterNotes('nothing matches'); assert($('notes-status').textContent==='No matching notes.','Empty search');
      filterNotes('wget'); assert(row(orphan).textContent.includes('Not installed'),'Removed package remains visible');
      const wget={id:orphan,type:'formula',name:'wget',version:'1'};
      setInventory({...sample,formulae:[...sample.formulae,wget]});
      assert(!row(orphan).textContent.includes('Not installed') && notesSearch.value==='wget','Reinstall updates badge in place');
      setInventory(sample);row(orphan).querySelector('[data-action="ask"]').click();
      row(orphan).querySelector('[data-action="cancel"]').click();
      assert(packageNotes.has(orphan) && notesDialog.open,'Cancel keeps the note');
      row(orphan).querySelector('[data-action="ask"]').click();
      return true;
      """)
    try HomebrewOperationLock.withLock(at: store.file, lockName: ".package-notes.lock") {
      _ = try page.run("""
        row('formula:wget').querySelector('[data-action="delete"]').click();
        await until(() => $('notes-status').textContent.includes('Could not delete'));
        assert(packageNotes.has('formula:wget'),'Failed delete retains the note');return true;
        """)
    }
    try page.run("""
      row('formula:wget').querySelector('[data-action="delete"]').click();
      await until(() => !packageNotes.has('formula:wget'));
      filterNotes('');assert(notesList.children.length===2,'Only the confirmed note disappears');
      $('notes-done').click(); await until(() => !popupScroll);
      assert(document.activeElement===$('search'),'Done returns focus to the inventory');
      return true;
      """)
    XCTAssertEqual(try store.read(), [formula: "Use for <clips>", cask: "Player"])
    XCTAssertTrue(page.messages.values.isEmpty)
  }
}
