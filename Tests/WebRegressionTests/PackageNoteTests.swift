import XCTest
@testable import BrewPeek

final class PackageNoteTests: XCTestCase {
  func testUsedByShowsNotesForInstalledFormulaIdentitiesAndRefreshesAfterEdits() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PackageNotes(file: directory.appendingPathComponent("notes.json"))
    for (id, text) in [
      ("formula:vendor/tools/jq", "배포 <script>"), ("formula:jq", "Old core note"),
      ("formula:other/tools/jq", "Other tap"), ("cask:php", "Cask only"),
    ] {
      _ = try store.save(id: id, text: text)
    }
    let page = try WebTestPage(notesDirectory: directory)
    try page.run("""
      const formula = (name, fullName = name) => ({id:'formula:'+fullName,name,type:'formula',version:'1'});
      const jq = formula('jq','vendor/tools/jq'), php = formula('php');
      const library = {...formula('oniguruma'),usedBy:['jq','php']};
      const data = {formulae:[library,jq,php],casks:[{id:'cask:php',name:'php',type:'cask',version:'1',apps:[]}],taps:[],environment:{}};
      const row = id => document.querySelector('.package-row[data-key="' + id + '"]');
      const detail = id => row(id).nextElementSibling;
      const entries = () => [...detail(library.id).querySelectorAll('.used-by-list li')];
      const waitFor = async predicate => {
        for (let i=0; i<150; i++) {
          if (predicate()) return;
          await new Promise(resolve => setTimeout(resolve, 15));
        }
        throw Error('Used by notes did not update');
      };
      setInventory(data);
      row(library.id).querySelector('button').click();
      await waitFor(() => notesReady);
      assert(entries().length === 2 && entries()[0].textContent === 'jqMy note: 배포 <script>', 'Unique short label maps to installed tapped formula');
      assert(entries()[1].textContent === 'php' && !entries()[1].querySelector('.used-by-note'), 'No note line for the unannotated formula despite a same-name cask');
      assert(!entries()[0].querySelector('script'), 'Note renders as text');

      const refresh = (users, parents) => setInventory({...data,formulae:[{...library,usedBy:users},...parents]});
      const other = formula('jq','other/tools/jq');
      refresh(['other/tools/jq','vendor/tools/jq'], [jq,other]);
      assert(entries()[0].textContent.endsWith('Other tap') && entries()[1].textContent.endsWith('배포 <script>'), 'Two taps with the same short name keep distinct notes');
      refresh(['jq','vendor/tools/jq'], [formula('jq'),jq]);
      assert(entries()[0].textContent.endsWith('Old core note'), 'Core full name wins when a tapped formula shares its name');
      row(jq.id).querySelector('button').click();
      const edit = text => {
        detail(jq.id).querySelector('[data-note-action="edit"]').click();
        const input = detail(jq.id).querySelector('textarea');
        input.value = text; input.dispatchEvent(new Event('input',{bubbles:true}));
        detail(jq.id).querySelector('[data-note-action="save"]').click();
      };
      edit('Updated note');
      await waitFor(() => entries()[1]?.textContent.endsWith('Updated note'));
      edit('');
      await waitFor(() => entries()[1]?.textContent === 'vendor/tools/jq');
      refresh([], []);
      assert(!detail(library.id).querySelector('.used-by-list') &&
        [...detail(library.id).querySelectorAll('dt')].find(dt=>dt.textContent.startsWith('USED BY')).nextElementSibling.textContent === '—',
        'An empty relationship keeps its placeholder');
      return true;
      """)
  }

  func testUpdatePlanShowsSavedNotesForSelectedAndRelatedIdentities() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = PackageNotes(file: directory.appendingPathComponent("notes.json"))
    _ = try store.save(id: "formula:demo", text: "After delivery")
    _ = try store.save(id: "formula:vendor/tools/demo", text: "영상 <clip>")
    let page = try WebTestPage(notesDirectory: directory)
    try page.run("""
      const pkg = (id, reason) => ({id, type:id.split(':')[0], name:'demo', version:'1',
        availableVersion:'2', reason, apps:[]});
      const a=pkg('formula:demo','Selected'), b=pkg('formula:vendor/tools/demo','Dependency'), c=pkg('cask:demo','Selected');
      b.relationship='Required by demo';
      setInventory({formulae:[a,b], casks:[c], taps:[], environment:{}});
      const plan={selectedCount:2,packages:[a,b,c],token:'fixture'};
      packageNotes.clear();
      showPlan(plan,false);
      const notes=()=>[...$('confirm-list').querySelectorAll('.confirmation-note:not([hidden])')];
      assert(!notes().length,'A plan can open before the note store replies');
      await loadPackageNotes();
      assert(notes().length===2 && notes()[0].textContent==='After delivery' && notes()[1].textContent==='영상 <clip>',
        'Selection and dependency notes follow their exact package IDs');
      assert(!$('confirm-list').querySelector('clip') && $('confirm-list').rows[1].textContent.includes('Required by demo'),
        'Notes render as text beneath the existing relationship');
      assert($('confirm-list').rows[2].querySelector('.confirmation-note').getClientRects().length===0,
        'Unannotated cask adds no space');
      showPlan({...plan,packages:[c,a]},true);
      assert(notes().length===1 && notes()[0].textContent==='After delivery','Rechecked plan drops removed dependencies');
      return true;
      """)
    XCTAssertTrue(page.messages.values.isEmpty)
  }

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
        assert([...document.querySelectorAll('#confirm-list .confirmation-note:not([hidden])')].length === 1 &&
          document.querySelector('#confirm-list tr:nth-child(2) .confirmation-note').textContent === '영상 <clip>',
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
