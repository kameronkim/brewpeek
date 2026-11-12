import XCTest

final class TrustApprovalUITests: XCTestCase {
  func testExplicitTrustConsentAndRecoveryNeverApproveAnUpdate() throws {
    let page = try WebTestPage(width: 900, height: 760)
    try page.run("""
      inventoryRefreshState='idle';
      window.trustPlan={operation:'trust',token:'consent',keys:['cask:vendor/tools/app'],packages:[{id:'cask:vendor/tools/app',name:'vendor/tools/app',type:'cask',source:'<img src=x onerror=alert(1)>',trust:'untrusted'}]};
      showPlan(trustPlan,false);
      assert(document.getElementById('start').textContent==='Trust packages','Explicit trust button');
      assert(document.getElementById('confirm-copy').textContent.includes('no package update will start'),'Separate consent copy');
      assert(!document.querySelector('#confirm-list img'),'Trust source escaped');
      document.getElementById('cancel').click(); return true;
      """)
    try page.wait { page.messages.values.count == 1 }
    XCTAssertEqual(page.messages.values[0]["action"] as? String, "cancel")
    try page.run("updateMode='ready'; showPlan(trustPlan,false); document.getElementById('start').click(); return true;")
    try page.wait { page.messages.values.count == 2 }
    XCTAssertEqual(page.messages.values[1]["action"] as? String, "startTrust")
    try page.run("""
      receiveUpdate({kind:'trusting',requestID:activeRequest});
      assert(updateMode==='trusting' && document.getElementById('cancel').disabled,'Trust commit cannot be interrupted by UI');
      assert(cancelUpdate()===false,'Escape must not interrupt an approved write');
      receiveUpdate({kind:'checking',operation:'update',requestID:activeRequest});
      receiveUpdate({kind:'plan',plan:{token:'update-consent',selectedCount:1,packages:[{id:'cask:vendor/tools/app',name:'app',version:'1',availableVersion:'2',reason:'Selected'}]},requestID:activeRequest});
      assert(updateMode==='confirming' && document.getElementById('start').textContent==='Update','Update requires separate confirmation');
      assert(document.querySelector('.confirm-table th').textContent==='Name','Update headers restored');
      restoreUpdateState([{kind:'plan',plan:trustPlan,requestID:'restored'}]);
      assert(operationKind==='trust' && requestedKeys[0]==='cask:vendor/tools/app','Trust plan restored without executing writes');
      return true;
      """)
    XCTAssertEqual(page.messages.values.count, 2, "No automatic update or replayed trust mutation")
  }
}
