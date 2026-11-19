import XCTest
@testable import BrewPeek

final class PackageNoteTests: XCTestCase {
  func testNotesSurviveRefreshAndRelaunchAndFollowRemovalIdentities() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let inventory = """
      const pkg = (id) => ({id, name:'demo', type:id.split(':')[0], direct:true, apps:[], description:'Original description', version:'1'});
      const formula = pkg('formula:vendor/tools/demo'), cask = pkg('cask:demo');
      const data = {formulae:[formula], casks:[cask], environment:{}, taps:[]};
      setInventory(data);
      const ready = async predicate => {
        for (let i=0; i<150; i++) {
          if (predicate()) return;
          await new Promise(resolve => setTimeout(resolve, 15));
        }
        throw Error('Timed out waiting for note');
      };
      await ready(() => notesReady);
      const row = () => document.querySelector('#formula .package-row');
      """
    do {
      let page = try WebTestPage(notesDirectory: directory)
      try page.run(inventory + """
        row().querySelector('button').click();
        document.querySelector('[data-note-action="edit"]').click();
        const editor = document.querySelector('.note-editor');
        editor.value = '영상 <clip>';
        editor.dispatchEvent(new Event('input', {bubbles:true}));
        setInventory(data);
        assert(document.activeElement.value === '영상 <clip>', 'Refresh keeps draft and focus');
        document.querySelector('[data-note-action="save"]').click();
        await ready(() => row().querySelector('.personal-note')?.textContent === '영상 <clip>');
        assert(!document.querySelector('clip'), 'Note is plain text');
        const search = document.getElementById('search');
        search.value = '영상'; search.dispatchEvent(new Event('input'));
        assert(document.querySelectorAll('.package-row').length === 1, 'Note search uses the full package identity');
        setInventory({...data, formulae:[]}); setInventory(data);
        assert(row().querySelector('.personal-note'), 'Removing and reinstalling a package retains its note');
        const plan = {operation:'uninstall', token:'fixture', packages:[cask, formula], selectedCount:1};
        showPlan(plan, false);
        assert([...document.querySelectorAll('#confirm-list .removal-note:not([hidden])')].length === 1 &&
          document.querySelector('#confirm-list tr:nth-child(2) .removal-note').textContent === '영상 <clip>',
          'Only matching removal target receives the note');
        return true;
        """)
    }
    let reopened = try WebTestPage(notesDirectory: directory)
    try reopened.run(inventory + """
      assert(row().querySelector('.personal-note').textContent === '영상 <clip>', 'Load from disk');
      row().querySelector('button').click();
      assert(row().nextElementSibling.textContent.includes('Original description'), 'Original description in details');
      document.querySelector('[data-note-action="edit"]').click();
      document.querySelector('[data-note-action="cancel"]').click();
      assert(packageNotes.get(formula.id) === '영상 <clip>', 'Cancel keeps saved text');
      document.querySelector('[data-note-action="edit"]').click();
      const input = document.querySelector('.note-editor'); input.value='';
      input.dispatchEvent(new Event('input', {bubbles:true})); document.querySelector('[data-note-action="save"]').click();
      await ready(() => !row().querySelector('.personal-note'));
      assert(row().querySelector('.description').textContent === 'Original description', 'Clearing restores fallback');
      return true;
      """)
    XCTAssertEqual(try PackageNotes(file: directory.appendingPathComponent("notes.json")).read(), [:])
  }
}
