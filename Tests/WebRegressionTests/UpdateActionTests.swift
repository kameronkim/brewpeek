import XCTest

final class UpdateActionTests: XCTestCase {
  func testQuitRequestApprovedRetryAndOrdinaryRetryKeepSeparateActions() throws {
    let page = try WebTestPage(width: 900, height: 760)
    try page.run("""
      inventoryRefreshState='idle'; operationKind='update'; activeRequest='blocked'; requestedKeys=['cask:example'];
      showCheckError('Close app',['Example'],'approved');
      assert(!$('quit-update-apps').hidden && $('quit-update-apps').textContent==='Quit app','Single app quit request visible');
      $('quit-update-apps').click(); return true;
      """)
    try page.wait { page.messages.values.count == 1 }
    XCTAssertEqual(page.messages.values[0]["action"] as? String, "quitUpdateApps")
    XCTAssertEqual(page.messages.values[0]["token"] as? String, "approved")
    try page.run("""
      receiveUpdate({kind:'appQuitRequested',requestID:activeRequest,message:'Quit requested'});
      assert($('quit-update-apps').disabled,'No duplicate quit request');
      assert(updateMode==='check-failed','Quit request does not start update');
      $('retry-plan').click(); return true;
      """)
    try page.wait { page.messages.values.count == 2 }
    XCTAssertEqual(page.messages.values[1]["action"] as? String, "start")
    XCTAssertEqual(page.messages.values[1]["token"] as? String, "approved")
    try page.run("showCheckError('Cannot check',[],null); $('retry-plan').click(); return true;")
    try page.wait { page.messages.values.count == 3 }
    XCTAssertEqual(page.messages.values[2]["action"] as? String, "prepare")
    XCTAssertEqual(page.messages.values[2]["keys"] as? [String], ["cask:example"])
  }
  func testVersionSelectionColumnsAndProgressCopyAcrossOperations() throws {
    let page = try WebTestPage()
    try page.run("""
      inventoryRefreshState='idle';
      const versions={operation:'version-cleanup',token:'versions',key:'formula:demo',packages:[
        {id:'formula:demo@1',name:'demo',version:'1',removable:true,reason:'Old installed version'},
        {id:'formula:demo@2',name:'demo',version:'2',removable:false,reason:'Kept by Homebrew'}]};
      showPlan(versions,false);
      const heads=()=>[...document.querySelectorAll('.confirm-table th')].filter(h=>!h.hidden);
      assert(heads().length===2 && heads()[1].textContent==='Version','Version selection has two visible columns');
      assert([...document.querySelectorAll('#confirm-list tr')].every(r=>r.cells.length===2),'Rows match visible columns');
      assert(!$('confirm-list').textContent.includes('Old installed version'),'No repeated removable-version explanation');
      assert($('confirm-list').textContent.includes('Kept by Homebrew'),'Protected version keeps context');
      assert($('start').disabled,'Selection still required');
      const checkbox=document.querySelector('[data-remove-version]');
      checkbox.checked=true;checkbox.dispatchEvent(new Event('change',{bubbles:true}));
      assert(!$('start').disabled,'Selection enables removal');
      showPlan({operation:'trust',keys:['formula:vendor/tools/demo'],packages:[{name:'demo',type:'formula',source:'vendor/tools'}]},false);
      assert(heads().length===3 && heads()[2].textContent==='Trust','Trust restores third column');
      showPlan(versions,false);
      const update={operation:'update',selectedCount:1,token:'update',packages:[{id:'formula:demo',name:'demo',version:'1',availableVersion:'2',reason:'Selected'}]};
      showPlan(update,false);
      assert(heads().length===3 && heads()[2].textContent==='New','Update restores third column');
      assert([...document.querySelectorAll('.confirm-table col')].every(c=>!c.hidden),'Update columns restored');
      $('confirm').close();
      beginProgress(update);
      assert($('operation-copy').hidden && !$('operation-copy').textContent,'No implementation explanation during updates');
      receiveUpdate({kind:'verifying'});
      assert(!$('operation-copy').hidden && $('operation-copy').textContent.includes('Confirming actual versions'),'Verification stage remains visible');
      return true;
      """)
    XCTAssertTrue(page.messages.values.isEmpty)
  }

}
