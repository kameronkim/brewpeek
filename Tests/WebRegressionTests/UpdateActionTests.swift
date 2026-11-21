import XCTest

final class UpdateActionTests: XCTestCase {
  func testQuitOfferPreferenceCancellationAndUpdateEndingWithOpenDialog() throws {
    let page = try WebTestPage(width: 480)
    try page.run("""
      activeRequest='current';
      beginProgress({packages:[{id:'cask:sample',name:'Sample'}]});
      const offer=(apps,reopen)=>receiveUpdate({kind:'offerUpdateQuit',requestID:'current',apps,reopen});
      offer(['Sample'],true);
      assert($('notice').open && $('notice-reopen').checked, 'Default checked');
      assert($('notice-reopen-label').textContent==='Reopen Sample before quitting', 'One named app');
      assert(document.activeElement===$('notice-ok'), 'Keep open receives focus');
      $('notice-reopen').click();
      offer(['Sample'],true);
      assert(!$('notice-reopen').checked, 'Repeated close preserves draft');
      $('schedule-quit').click();
      receiveUpdate({kind:'quitScheduled',requestID:'current',scheduled:true});
      assert(!$('notice').open && !$('quit-status').hidden,'Reservation is visible');
      $('quit-status').querySelector('button').click();
      receiveUpdate({kind:'quitScheduled',requestID:'current',scheduled:false});
      assert($('quit-status').hidden && updateMode==='running','Only the reservation was cancelled');
      offer(['Photo','Video'],false);
      assert(!$('notice-reopen').checked && $('notice-reopen-label').textContent==='Reopen 2 apps before quitting','Saved opt-out and plural');
      $('notice-reopen').click();
      $('notice').dispatchEvent(new Event('cancel',{cancelable:true}));
      assert(!$('notice').open,'Escape dismisses the draft');
      offer([],false);
      assert(!$('notice-reopen-option').getClientRects().length,'No empty reopen option');
      receiveUpdate({kind:'result',requestID:'current',packages:[],verified:true});
      assert(!$('notice').open && !$('quit-status'),'Finishing expires the offer');
      receiveUpdate({kind:'offerUpdateQuit',requestID:'current',apps:[],reopen:false});
      assert(!$('notice').open,'Late offer ignored');
      receiveUpdate({kind:'closeBlocked',message:'Finishing another operation'});
      assert($('notice-ok').textContent==='OK' && $('schedule-quit').hidden,'Ordinary close notice is restored');
      return true;
      """)
    try page.wait { page.messages.values.count == 3 }
    XCTAssertEqual(page.messages.values.compactMap { $0["action"] as? String },
      ["scheduleQuit", "cancelScheduledQuit", "cancelScheduledQuit"])
    XCTAssertEqual(page.messages.values.first?["reopen"] as? Bool, false)
    XCTAssertTrue(page.messages.values.allSatisfy { $0["requestID"] as? String == "current" })
  }

  func testReopenUsesTheVerifiedAppInTheRetainedResult() throws {
    let page = try WebTestPage(width: 480)
    try page.run("""
      inventoryRefreshState='idle';
      const row = (id, outcome) => ({id, name:id.split(':')[1], outcome, message:outcome, actualVersion:'2'});
      restoreUpdateState([{kind:'result', requestID:'done', verified:true,
        packages:[row('cask:studio','updated'),row('formula:studio','updated'),row('cask:other','failed')],
        reopenApps:{photo:{packageID:'cask:studio',name:'Photo'},video:{packageID:'cask:studio',name:'Video'}}}]);
      $('operation-view').click();
      const rows=document.querySelectorAll('.result-list li');
      assert(rows[0].querySelectorAll('[data-reopen]').length===2,'Both closed apps available');
      assert(!rows[1].querySelector('button')&&!rows[2].querySelector('button'),'Only the matching Cask has buttons');
      const video=rows[0].querySelector('[data-reopen="video"]');
      assert(video.textContent==='Reopen Video','Distinguishable apps');
      video.click(); return true;
      """)
    try page.wait { page.messages.values.count == 1 }
    XCTAssertEqual(page.messages.values.first as? [String: String],
      ["action": "reopenUpdatedApp", "resultID": "done", "token": "video"])
    try page.run("""
      receiveUpdate({kind:'reopenFinished',resultID:'old',token:'video'});
      assert(document.querySelector('[data-reopen="video"]'),'Old callback ignored');
      receiveUpdate({kind:'reopenFinished',resultID:'done',token:'video',message:'Fixture error'});
      assert($('notice').open&&document.querySelector('[data-reopen="video"]'),'Can retry a launch failure');
      $('notice-ok').click();
      receiveUpdate({kind:'reopenFinished',resultID:'done',token:'video'});
      assert(!document.querySelector('[data-reopen="video"]')&&document.querySelector('[data-reopen="photo"]'),'Only the opened app is consumed');
      paintResult(previousResult);
      assert(document.querySelector('[data-reopen="photo"]').textContent==='Reopen','Single remaining app has a short label');
      return true;
      """)
    XCTAssertEqual(page.messages.values.count, 1)
  }

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
